"""Decode three actual uint8 FPGA heads; no neural inference runs here."""
import numpy as np


def sigmoid(value):
    return 1 / (1 + np.exp(-np.clip(value, -80, 80)))


def nms(boxes, scores, threshold):
    order = np.argsort(-scores, kind='stable')
    keep = []
    area = np.maximum(0, boxes[:, 2]-boxes[:, 0]) * np.maximum(0, boxes[:, 3]-boxes[:, 1])
    while len(order):
        first = order[0]
        keep.append(first)
        other = order[1:]
        low = np.maximum(boxes[first, :2], boxes[other, :2])
        high = np.minimum(boxes[first, 2:], boxes[other, 2:])
        overlap = np.maximum(0, high-low).prod(axis=1)
        iou = overlap / np.maximum(area[first]+area[other]-overlap, 1e-12)
        order = other[iou <= threshold]
    return np.asarray(keep, dtype=np.int64)


def decode_heads(heads, parameters, anchors, image_shape, confidence=0.5, nms_iou=0.3,
                 input_size=640, letterbox=None):
    """Return [x1,y1,x2,y2,score,class_id] in original image coordinates.

    heads must be out1/out2/out3 uint8 CHW in descending stride order.
    parameters contains their output_scale and output_zero_point.
    Default is the verified 640 direct-resize release. For a 320 letterbox
    graph, supply its input_size and exact geometry from model_input.py.
    """
    if len(heads) != 3 or len(parameters) != 3:
        raise ValueError('three detection heads are required')
    anchors = np.asarray(anchors, dtype=np.float32).reshape(9, 2)
    masks = ((6, 7, 8), (3, 4, 5), (0, 1, 2))
    records = []
    class_count = None
    for index, (head, params) in enumerate(zip(heads, parameters)):
        if head.dtype != np.uint8 or head.ndim != 3 or head.shape[0] % 3:
            raise ValueError('expected uint8 CHW heads')
        channels, height, width = head.shape
        attributes = channels // 3
        if attributes < 6 or (class_count is not None and class_count != attributes-5):
            raise ValueError('inconsistent detection classes')
        class_count = attributes-5
        logits = (head.astype(np.float32)-params['output_zero_point'])*np.float32(params['output_scale'])
        pred = sigmoid(logits.reshape(3, attributes, height, width).transpose(0, 2, 3, 1))
        class_id = pred[..., 5:].argmax(axis=-1)
        score = pred[..., 4] * pred[..., 5:].max(axis=-1)
        selected = score >= confidence
        grid_y, grid_x = np.meshgrid(np.arange(height), np.arange(width), indexing='ij')
        grid = np.stack((grid_x, grid_y), axis=-1)
        xy = (pred[..., :2]*2-0.5+grid) * np.array((input_size/width, input_size/height))
        wh = (pred[..., 2:4]*2)**2 * anchors[list(masks[index])][:, None, None, :]
        boxes = np.concatenate((xy-wh/2, xy+wh/2), axis=-1)
        records.append(np.concatenate((boxes[selected], score[selected, None], class_id[selected, None]), axis=1))
    records = np.concatenate(records, axis=0)
    if not len(records):
        return np.empty((0, 6), dtype=np.float64)
    keep = []
    for category in np.unique(records[:, 5]):
        subset = np.flatnonzero(records[:, 5] == category)
        keep.extend(subset[nms(records[subset, :4], records[subset, 4], nms_iou)])
    result = records[keep]
    result = result[np.argsort(-result[:, 4], kind='stable')]
    ih, iw = image_shape[:2]
    if letterbox is None:
        result[:, :4] *= np.array((iw/input_size, ih/input_size, iw/input_size, ih/input_size))
    else:
        if letterbox['size'] != input_size:
            raise ValueError('letterbox geometry does not match model size')
        result[:, :4] -= np.array((letterbox['left'], letterbox['top'],
                                   letterbox['left'], letterbox['top']))
        result[:, :4] /= np.array((letterbox['scale_x'], letterbox['scale_y'],
                                   letterbox['scale_x'], letterbox['scale_y']))
        result[:, (0, 2)] = np.clip(result[:, (0, 2)], 0, iw)
        result[:, (1, 3)] = np.clip(result[:, (1, 3)], 0, ih)
    return result


def main():
    import argparse
    import json
    from pathlib import Path
    import cv2
    parser = argparse.ArgumentParser(description='Decode complete raw detection heads, not CRC samples')
    parser.add_argument('heads', type=Path, help='directory containing out1.bin, out2.bin, out3.bin')
    parser.add_argument('--image', type=Path, required=True, help='original input image')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--confidence', type=float, default=.5)
    parser.add_argument('--nms-iou', type=float, default=.3)
    parser.add_argument('--graph', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    model = root/'work/model_extract/yolov5-v6.1-pytorch-master'
    graph = json.loads((args.graph or root/'outputs/network_graph.json').read_text())
    heads, params = [], []
    for name in ('out1', 'out2', 'out3'):
        info = graph['tensors'][name]
        path = args.heads/f'{name}.bin'
        data = path.read_bytes()
        if len(data) != info['bytes']:
            raise SystemExit(f'{name}: need {info["bytes"]} bytes, received {len(data)}; incomplete heads cannot be decoded')
        heads.append(np.frombuffer(data, dtype=np.uint8).reshape(info['shape'][1:]))
        params.append(next(node['parameters'] for node in graph['nodes'] if node['name'] == name))
    image = cv2.imdecode(np.fromfile(args.image, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit('cannot read original input image')
    anchors = np.fromstring((model/'model_data/yolo_anchors.txt').read_text(), sep=',')
    classes = (model/'model_data/voc_classes.txt').read_text().splitlines()
    if len(classes) != heads[0].shape[0]//3-5:
        raise SystemExit('class labels do not match detection head channels')
    input_size = graph.get('input_size', 640)
    geometry = None
    if graph.get('preprocessing') == 'letterbox':
        from model_input import letterbox_bgr
        geometry = letterbox_bgr(image, input_size)[1]
    boxes = decode_heads(heads, params, anchors, image.shape, args.confidence, args.nms_iou,
                         input_size=input_size, letterbox=geometry)
    records = []
    for x1, y1, x2, y2, score, category in boxes:
        category = int(category)
        records.append(dict(box=[float(x1), float(y1), float(x2), float(y2)],
                            score=float(score), class_id=category, label=classes[category]))
        cv2.rectangle(image, (round(x1), round(y1)), (round(x2), round(y2)), (0, 255, 0), 2)
        cv2.putText(image, f'{classes[category]} {score:.2f}', (round(x1), max(18, round(y1)-4)),
                    cv2.FONT_HERSHEY_SIMPLEX, .6, (0, 255, 0), 2)
    output = args.output or root/'outputs/detections.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    success, encoded = cv2.imencode('.png', image)
    if not success:
        raise SystemExit('cannot encode annotated image')
    encoded.tofile(output)
    output.with_suffix('.json').write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'decoded {len(records)} detections from complete supplied raw heads; output={output}')


if __name__ == '__main__':
    main()
