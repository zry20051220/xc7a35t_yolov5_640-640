#include "npu_packed.h"
#ifndef NPU_PACKED_PE
#define NPU_PACKED_PE 8
#endif
#ifndef NPU_ROWS_CAPACITY
#define NPU_ROWS_CAPACITY 32768
#endif
#ifndef NPU_MAX_WIDTH
#define NPU_MAX_WIDTH 320
#endif
#ifndef NPU_MAX_TAPS
#define NPU_MAX_TAPS 4608
#endif

static ap_uint<8> byte_at(memory_word value, unsigned int address) {
#pragma HLS INLINE
    return (value >> ((address & 7) * 8)).range(7,0);
}
static ap_uint<8> read_byte(const memory_word *memory, unsigned int address) {
#pragma HLS INLINE
    return byte_at(memory[address >> 3], address);
}
static int packed_row_product(int row, int width) {
#pragma HLS INLINE off
#pragma HLS LATENCY min=3 max=3
    return row * width;
}
static ap_uint<8> quantized_clamp(ap_int<64> shifted, int zp, bool relu) {
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
#pragma HLS LATENCY min=2
    // Saturate BEFORE adding zp: a 64-bit barrel shift followed by a
    // 64-bit carry chain was the first board candidate's critical path.
    ap_int<10> zero=zp;
    ap_int<10> lower=relu ? (ap_int<10>)0 : (ap_int<10>)(-zero);
    ap_int<10> upper=(ap_int<10>)255-zero;
    if(shifted<lower)return relu ? (ap_uint<8>)zero : (ap_uint<8>)0;
    if(shifted>upper)return 255;
    ap_int<10> narrow=shifted;
    return (ap_uint<8>)(narrow+zero);
}
static ap_uint<8> scale_value(ap_int<32> value, ap_int<64> bias,
                             int multiplier, int shift, int zp, bool relu) {
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
    ap_int<64> scaled = value * (ap_int<32>)multiplier + bias;
    ap_uint<6> shift_bits=shift;
    if (shift > 0) scaled = (scaled + ((ap_int<64>)1 << (shift_bits-1))) >> shift_bits;
    return quantized_clamp(scaled,zp,relu);
}

// A single 64-bit width on ALL ports permits burst inference in HLS 2018.3.
// Byte-addressed AXI-Lite base addresses remain unchanged. Data are little-endian.
void npu_conv(const memory_word *input, const memory_word *weights,
              const memory_word *bias, memory_word *output,
              int in_h, int in_w, int in_c, int out_c,
              int kernel, int stride, int pad,
              int input_zero_point, int weight_zero_point, int output_zero_point,
              int scale_multiplier, int scale_shift, bool relu) {
#pragma HLS INTERFACE m_axi port=input offset=slave bundle=gmem0 depth=8192
#pragma HLS INTERFACE m_axi port=weights offset=slave bundle=gmem0 depth=8192
#pragma HLS INTERFACE m_axi port=bias offset=slave bundle=gmem0 depth=65536
#pragma HLS INTERFACE m_axi port=output offset=slave bundle=gmem0 depth=8192
#pragma HLS INTERFACE s_axilite port=return bundle=control
#pragma HLS INTERFACE s_axilite port=in_h bundle=control
#pragma HLS INTERFACE s_axilite port=in_w bundle=control
#pragma HLS INTERFACE s_axilite port=in_c bundle=control
#pragma HLS INTERFACE s_axilite port=out_c bundle=control
#pragma HLS INTERFACE s_axilite port=kernel bundle=control
#pragma HLS INTERFACE s_axilite port=stride bundle=control
#pragma HLS INTERFACE s_axilite port=pad bundle=control
#pragma HLS INTERFACE s_axilite port=input_zero_point bundle=control
#pragma HLS INTERFACE s_axilite port=weight_zero_point bundle=control
#pragma HLS INTERFACE s_axilite port=output_zero_point bundle=control
#pragma HLS INTERFACE s_axilite port=scale_multiplier bundle=control
#pragma HLS INTERFACE s_axilite port=scale_shift bundle=control
#pragma HLS INTERFACE s_axilite port=relu bundle=control
    if(kernel==0) {
ELEMENT_WORD: for(int word=0;word<(in_h+7)/8;++word) {
            memory_word a=input[word],b=0,result=0;
            if(stride!=1)b=weights[word];
ELEMENT_BYTE: for(int lane=0;lane<8;++lane) {
#pragma HLS PIPELINE II=1
#ifdef NPU_ELEMENT_TWO
#pragma HLS UNROLL factor=2
#endif
                int index=word*8+lane;
                if(index<in_h) {
                    ap_uint<8> av=byte_at(a,lane),bv=byte_at(b,lane);
                    ap_int<64> scaled;
                    if(stride==2) scaled=(ap_int<64>)bias[((unsigned int)av<<8)|(unsigned int)bv];
                    else {
                        ap_int<10> da=(ap_int<10>)av-(ap_int<10>)input_zero_point;
                        ap_int<42> pa=da*(ap_int<32>)scale_multiplier;
                        scaled=pa;
                        if(stride==0) {
                            ap_int<10> db=(ap_int<10>)bv-(ap_int<10>)in_c;
                            ap_int<42> pb=db*(ap_int<32>)in_w;
                            scaled+=pb;
                        }
                        ap_uint<6> shift_bits=scale_shift;
                        if(scale_shift>0)scaled=(scaled+((ap_int<64>)1<<(shift_bits-1)))>>shift_bits;
                        scaled=quantized_clamp(scaled,output_zero_point,false);
                    }
                    result.range(lane*8+7,lane*8)=(ap_uint<8>)scaled;
                }
            }
            // Preserve bytes outside a non-multiple-of-eight tensor.
            int remaining=in_h-word*8;
            if(remaining<8) {
                memory_word mask=((memory_word)1<<(remaining*8))-1;
                result=(output[word]&~mask)|(result&mask);
            }
            output[word]=result;
        }
        return;
    }
#ifdef NPU_UPSAMPLE_WORDS
    // Aligned four-byte input groups expand into complete 64-bit output words.
    // Buffer an expanded row once, then emit its two nearest-neighbor copies.
    // Odd widths keep the established byte path, including masked final words.
    if(kernel==4 && in_h>0 && in_c>0 && in_w>0 && in_w<=NPU_MAX_WIDTH && in_w%4==0) {
        memory_word expanded_row[NPU_MAX_WIDTH/4];
#pragma HLS RESOURCE variable=expanded_row core=RAM_2P_BRAM
        int row_words=in_w/4;
UP_C: for(int c=0;c<in_c;++c) {
UP_Y: for(int y=0;y<in_h;++y) {
                int source=(c*in_h+y)*in_w;
                int destination=(c*in_h*2+y*2)*row_words;
                memory_word cached=0; int previous=-1;
UP_EXPAND: for(int x=0;x<row_words;++x) {
                    int address=source+x*4,word=address>>3;
                    if(word!=previous){cached=input[word];previous=word;}
                    memory_word value=0;
UP_BYTES: for(int lane=0;lane<4;++lane) {
#pragma HLS UNROLL
                        ap_uint<8> v=byte_at(cached,address+lane);
                        value.range(lane*16+7,lane*16)=v;
                        value.range(lane*16+15,lane*16+8)=v;
                    }
                    expanded_row[x]=value;
                }
UP_REPEAT: for(int repeat=0;repeat<2;++repeat) {
UP_WRITE: for(int x=0;x<row_words;++x) {
#pragma HLS PIPELINE II=1
                        output[destination+repeat*row_words+x]=expanded_row[x];
                    }
                }
            }
        }
        return;
    }
#endif
    if(kernel==4 || kernel==5) {
#ifdef NPU_SPECIAL_CACHE
        ap_uint<8> pool_cache[400];
#pragma HLS RESOURCE variable=pool_cache core=RAM_2P_BRAM
        if(kernel==5&&(in_h<1||in_h>400||in_w<1||in_w>400||in_h*in_w>400))return;
#endif
        int height=kernel==4 ? in_h*2 : in_h;
        int width=kernel==4 ? in_w*2 : in_w;
        int count=in_c*height*width;
        memory_word result=0;
        int lane=0,word=0;
SPECIAL_C: for(int c=0;c<in_c;++c) {
#ifdef NPU_SPECIAL_CACHE
            if(kernel==5) {
                int start=c*in_h*in_w;
                memory_word packed=0;int cached_word=-1;
POOL_LOAD: for(int i=0;i<in_h*in_w;++i) {
#pragma HLS PIPELINE II=1
                    int address=start+i,word=address>>3;
                    if(word!=cached_word){packed=input[word];cached_word=word;}
                    pool_cache[i]=byte_at(packed,address);
                }
            }
#endif
SPECIAL_Y: for(int y=0;y<height;++y) {
                int source_row = kernel==4 ? packed_row_product(c*in_h+y/2,in_w) : 0;
#ifdef NPU_SPECIAL_CACHE
                memory_word upsample_word=0;int cached_upsample=-1;
#endif
SPECIAL_X: for(int x=0;x<width;++x) {
                ap_uint<8> value=0;
                if(kernel==4) {
#ifdef NPU_SPECIAL_CACHE
                    int address=source_row+x/2,word=address>>3;
                    if(word!=cached_upsample){upsample_word=input[word];cached_upsample=word;}
                    value=byte_at(upsample_word,address);
#else
                    value=read_byte(input,source_row+x/2);
#endif
                }
                else {
POOL_Y: for(int ky=0;ky<5;++ky) {
POOL_X: for(int kx=0;kx<5;++kx) {
#pragma HLS PIPELINE II=1
                        int iy=y+ky-2,ix=x+kx-2;
                        if(iy>=0&&iy<in_h&&ix>=0&&ix<in_w) {
#ifdef NPU_SPECIAL_CACHE
                            ap_uint<9> row=iy,row_width=in_w;
                            ap_uint<9> address=row*row_width+ix;
                            ap_uint<8> v=pool_cache[address];
#else
                            ap_uint<8> v=read_byte(input,(c*in_h+iy)*in_w+ix);
#endif
                            if(v>value)value=v;
                        }
                    }
                    }
                }
                result.range(lane*8+7,lane*8)=value;
                ++lane;
                if(lane==8){output[word++]=result;result=0;lane=0;}
            }
            }
        }
        if(lane) {
            memory_word mask=((memory_word)1<<(lane*8))-1;
            output[word]=(output[word]&~mask)|(result&mask);
        }
        return;
    }
    const int PE=NPU_PACKED_PE;
#ifdef NPU_SINGLE_ACC
    // The generated DSP multiply-add is combinational with a one-cycle
    // registered feedback path. A single accumulator retains MAC II=1 and
    // removes the four-way 32-bit mux/feedback and final partial-sum tree.
    const int ACC_LANES=1;
#else
    const int ACC_LANES=4;
#endif
    // This user model has symmetric INT8 weights (zero point exactly zero).
    // Specializing removes signed dynamic-subtract arithmetic from each PE.
    if(weight_zero_point!=0||input_zero_point<0||input_zero_point>255||
       output_zero_point<0||output_zero_point>255||scale_shift<0||scale_shift>63||
       in_c<1||in_c>512||in_w<1||in_w>NPU_MAX_WIDTH||in_h<1||out_c<1||
       (kernel!=1&&kernel!=3)||(stride!=1&&stride!=2)||pad<0||pad>1||
#ifdef NPU_SINGLE_ROW_K1
       in_c*in_w*(kernel==1?1:3)>NPU_ROWS_CAPACITY||in_c*kernel*kernel>NPU_MAX_TAPS)return;
#else
       in_c*in_w*3>NPU_ROWS_CAPACITY||in_c*kernel*kernel>NPU_MAX_TAPS)return;
#endif
#ifdef NPU_PACKED_CACHE
    // Same byte capacity as the byte-addressed row cache; only its physical
    // word width changes. The MAC still reads the exact little-endian byte.
    memory_word rows[NPU_ROWS_CAPACITY/8];
#else
    ap_uint<8> rows[NPU_ROWS_CAPACITY];
#endif
    ap_int<8> wbuf[PE][NPU_MAX_TAPS];
    ap_int<64> bbuf[PE];
    ap_uint<8> obuf[PE][NPU_MAX_WIDTH];
#ifdef NPU_BURST_ROWS
    // Separate packed transfer loops are needed for automatic AXI bursts;
    // a conditional single-word read inside an 8-byte loop does not burst.
    memory_word row_words[NPU_MAX_WIDTH/8+2];
    memory_word weight_words[(NPU_MAX_TAPS+7)/8+2];
#pragma HLS RESOURCE variable=row_words core=RAM_2P_BRAM
#pragma HLS RESOURCE variable=weight_words core=RAM_2P_BRAM
#endif
#pragma HLS RESOURCE variable=rows core=RAM_2P_BRAM
#pragma HLS ARRAY_PARTITION variable=wbuf complete dim=1
#pragma HLS ARRAY_PARTITION variable=bbuf complete dim=1
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=1
    int ohn=(in_h+2*pad-kernel)/stride+1,own=(in_w+2*pad-kernel)/stride+1;
    if(own<1||own>NPU_MAX_WIDTH||ohn<1)return;
    ap_uint<16> row_stride=in_c*in_w;
    ap_uint<13> taps=in_c*kernel*kernel;
    ap_uint<10> width=in_w;
    ap_uint<2> ksize=kernel,step=stride;
OC: for(int ocbase=0;ocbase<out_c;ocbase+=PE) {
LOAD_P: for(int p=0;p<PE;++p) {
            int oc=ocbase+p;
            bbuf[p]=oc<out_c ? (ap_int<64>)bias[oc] : (ap_int<64>)0;
            int start=oc*(int)taps;
#ifdef NPU_BURST_ROWS
            int first_weight=start>>3;
            int weight_count=((start+(int)taps+7)>>3)-first_weight;
            if(oc<out_c) {
BURST_WEIGHT: for(int word=0;word<weight_count;++word) {
#pragma HLS PIPELINE II=1
                    weight_words[word]=weights[first_weight+word];
                }
            }
#else
            memory_word packed=0;
#endif
LOAD_W: for(int i=0;i<(int)taps;++i) {
#pragma HLS PIPELINE II=1
                unsigned int address=start+i;
#ifdef NPU_BURST_ROWS
                wbuf[p][i]=oc<out_c ? (ap_int<8>)byte_at(weight_words[(address>>3)-first_weight],address) : (ap_int<8>)0;
#else
                if(oc<out_c&&(i==0||(address&7)==0))packed=weights[address>>3];
                wbuf[p][i]=oc<out_c ? (ap_int<8>)byte_at(packed,address) : (ap_int<8>)0;
#endif
            }
        }
        ap_uint<2> front=0;
ROW: for(int oh=0;oh<ohn;++oh) {
LOAD_ROW: for(int kh=0;kh<kernel;++kh) {
                int ih=oh*stride+kh-pad;
                ap_uint<3> slot=front+kh;
#ifdef NPU_SINGLE_ROW_K1
                if(kernel==1)slot=0;
#endif
                if(slot>=3)slot-=3;
                if((oh==0||kh>=kernel-stride)&&ih>=0&&ih<in_h) {
LOAD_CHANNEL: for(int ic=0;ic<in_c;++ic) {
                        int start=(ic*in_h+ih)*in_w;
                        ap_uint<16> cached=(ap_uint<16>)slot*row_stride+ic*width;
#ifdef NPU_PACKED_CACHE
                        // Most real-model widths (160/80/40) and row bases are
                        // aligned. Burst directly into 64-bit BRAM, without
                        // spending eight cycles unpacking each received word.
                        if(((start|(unsigned int)cached|in_w)&7)==0) {
PACKED_INPUT: for(int word=0;word<in_w/8;++word) {
#pragma HLS PIPELINE II=1
                                rows[((unsigned int)cached>>3)+word]=input[(start>>3)+word];
                            }
                        } else {
                            int first_word=start>>3;
                            int word_count=((start+in_w+7)>>3)-first_word;
UNALIGNED_INPUT: for(int word=0;word<word_count;++word) {
#pragma HLS PIPELINE II=1
                                row_words[word]=input[first_word+word];
                            }
                            int first_cached=(unsigned int)cached>>3;
                            int last_cached=((unsigned int)cached+in_w-1)>>3;
CACHE_WORD: for(int word=first_cached;word<=last_cached;++word) {
                                memory_word value=0;
                                if(word*8<(unsigned int)cached||word*8+8>(unsigned int)cached+in_w)
                                    value=rows[word];
CACHE_BYTE: for(int lane=0;lane<8;++lane) {
#pragma HLS PIPELINE II=1
                                    int x=word*8+lane-(unsigned int)cached;
                                    if(x>=0&&x<in_w) {
                                        unsigned int address=start+x;
                                        value.range(lane*8+7,lane*8)=byte_at(row_words[(address>>3)-first_word],address);
                                    }
                                }
                                rows[word]=value;
                            }
                        }
#else
#ifdef NPU_BURST_ROWS
                        int first_word=start>>3;
                        int word_count=((start+in_w+7)>>3)-first_word;
BURST_INPUT: for(int word=0;word<word_count;++word) {
#pragma HLS PIPELINE II=1
                            row_words[word]=input[first_word+word];
                        }
#else
                        memory_word packed=0;
#endif
LOAD_X: for(int x=0;x<in_w;++x) {
#pragma HLS PIPELINE II=1
                            unsigned int address=start+x;
#ifdef NPU_BURST_ROWS
                            rows[cached+x]=byte_at(row_words[(address>>3)-first_word],address);
#else
                            if(x==0||(address&7)==0)packed=input[address>>3];
                            rows[cached+x]=byte_at(packed,address);
#endif
                        }
#endif
                    }
                }
            }
PIXEL: for(int ow=0;ow<own;++ow) {
                ap_int<32> sums[PE][ACC_LANES];
#pragma HLS ARRAY_PARTITION variable=sums complete dim=0
INIT_P: for(int p=0;p<PE;++p) {
#pragma HLS UNROLL
INIT_L: for(int lane=0;lane<ACC_LANES;++lane) {
#pragma HLS UNROLL
                        sums[p][lane]=0;
                    }
                }
                ap_uint<10> ic=0;
                ap_uint<2> ky=0,kx=0;
                ap_uint<16> channel_offset=0;
MAC: for(ap_uint<13> tap=0;tap<taps;++tap) {
#pragma HLS PIPELINE II=1
                    int iy=oh*stride+(int)ky-pad,ix=ow*stride+(int)kx-pad;
                    ap_uint<3> slot=front+ky;
#ifdef NPU_SINGLE_ROW_K1
                    if(kernel==1)slot=0;
#endif
                    if(slot>=3)slot-=3;
                    ap_int<10> a=0;
                    if(iy>=0&&iy<in_h&&ix>=0&&ix<in_w) {
                        ap_uint<15> address=(ap_uint<16>)slot*row_stride+channel_offset+ix;
#ifdef NPU_PACKED_CACHE
                        a=(ap_int<10>)byte_at(rows[address>>3],address)-(ap_int<10>)input_zero_point;
#else
                        a=(ap_int<10>)rows[address]-(ap_int<10>)input_zero_point;
#endif
                    }
MAC_P: for(int p=0;p<PE;++p) {
#pragma HLS UNROLL
                        ap_int<8> b=wbuf[p][tap];
#ifdef NPU_SINGLE_ACC
                        sums[p][0]+=a*b;
#else
                        sums[p][tap&3]+=a*b;
#endif
                    }
                    ++kx;
                    if(kx==ksize) {
                        kx=0;++ky;
                        if(ky==ksize){ky=0;++ic;channel_offset+=width;}
                    }
                }
STORE_P: for(int p=0;p<PE;++p) {
#pragma HLS PIPELINE II=1
#ifdef NPU_STORE_FOUR
#pragma HLS UNROLL factor=4
#endif
#ifdef NPU_SINGLE_ACC
                    ap_int<32> sum=sums[p][0];
#else
                    ap_int<32> sum=sums[p][0]+sums[p][1]+sums[p][2]+sums[p][3];
#endif
                    obuf[p][ow]=scale_value(sum,bbuf[p],scale_multiplier,scale_shift,output_zero_point,relu);
                }
            }
FLUSH_P: for(int p=0;p<PE;++p) {
                if(ocbase+p<out_c) {
                    int start=((ocbase+p)*ohn+oh)*own;
                    int first=start>>3,last=(start+own-1)>>3;
FLUSH_WORD: for(int word=first;word<=last;++word) {
                        memory_word value=0;
                        bool partial=word*8<start||word*8+8>start+own;
                        if(partial)value=output[word];
PACK_BYTE: for(int lane=0;lane<8;++lane) {
#pragma HLS PIPELINE II=1
                            int x=word*8+lane-start;
                            if(x>=0&&x<own)value.range(lane*8+7,lane*8)=obuf[p][x];
                        }
#ifdef NPU_BURST_ROWS
                        row_words[word-first]=value;
#else
                        output[word]=value;
#endif
                    }
#ifdef NPU_BURST_ROWS
                    int word_count=last-first+1;
BURST_OUTPUT: for(int word=0;word<word_count;++word) {
#pragma HLS PIPELINE II=1
                        output[first+word]=row_words[word];
                    }
#endif
                }
            }
            ap_uint<3> next=(ap_uint<3>)front+step;
            if(next>=3)next-=3;
            front=next;
        }
    }
}
