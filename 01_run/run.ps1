param([string]$Source='0',[switch]$CheckOnly)
$ErrorActionPreference='Stop'
$taskHere=$PSScriptRoot
$taskAcceptance=Get-Content (Join-Path $taskHere 'numerical_smoke.json') -Raw | ConvertFrom-Json
if (!$taskAcceptance.numerical_smoke_validated) {throw 'Missing numerical acceptance'}
foreach ($taskPair in @(@('head_qat640_candidate.bit',$taskAcceptance.bit_sha256),@('weights.bin',$taskAcceptance.weights_sha256),@('network_graph_640.json',$taskAcceptance.graph_sha256))) {
    if ((Get-FileHash -LiteralPath (Join-Path $taskHere $taskPair[0]) -Algorithm SHA256).Hash -ne $taskPair[1]) {throw 'Artifact hash mismatch'}
}
if ($CheckOnly) {Write-Output 'Delivery runtime hashes OK'; return}
Write-Warning 'Experimental head counter; full accuracy and long-run stability not accepted.'
& 'D:\Xilinx\Vivado\2018.3\bin\vivado.bat' -mode batch -source (Join-Path $taskHere 'program_board.tcl') -log (Join-Path $taskHere 'live_program.log') -journal (Join-Path $taskHere 'live_program.jou') -tclargs (Join-Path $taskHere 'head_qat640_candidate.bit')
if ($LASTEXITCODE -ne 0) {throw 'Programming failed'}
& 'C:\Python314\python.exe' -u (Join-Path $taskHere 'host\upload_weight_pages.py') (Join-Path $taskHere 'weights.bin') --frame-id 22999
if ($LASTEXITCODE -ne 0) {throw 'Weight upload failed'}
& 'C:\Python314\python.exe' -u (Join-Path $taskHere 'host\live_detector.py') --source $Source --graph (Join-Path $taskHere 'network_graph_640.json') --frame-id 23000 --packet-delay 0
if ($LASTEXITCODE -ne 0) {throw 'Detector failed'}
