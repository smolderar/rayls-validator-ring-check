# Nov Week 2, STEP 1 (read-only). Sender-affinity fork: full data run.
# No wallet, no transactions, zero cost. Only public RPC and explorer reads. All times printed in UTC.
# Windows: about 2 days before block 12,231,705 | about 2 days after it | about the last 24 hours.
# Output: step1-data.csv (one row per transaction) + step1-results.txt (summary).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'step1-results.txt'
$csv = Join-Path $PSScriptRoot 'step1-data.csv'
"" | Set-Content $out -Encoding UTF8
if (Test-Path $csv) { Remove-Item $csv }
function W($s) { $s | Add-Content $out -Encoding UTF8; Write-Host $s }

$RPC  = 'https://mainnet-rpc.rayls.com'
$EXP  = 'https://explorer.rayls.com'
$FORK = 12231705
$SPAN = 130000          # about 2 days of blocks (step 0 measured about 1.33 s per block)
$MAXPAGES = 100         # 50 transactions per explorer page

function Rpc($method, $params) {
  $body = @{ jsonrpc='2.0'; id=1; method=$method; params=$params } | ConvertTo-Json -Depth 8 -Compress
  try { $r = Invoke-RestMethod -Uri $RPC -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
        if ($r.error) { return "ERROR " + ($r.error | ConvertTo-Json -Compress) } ; return $r.result }
  catch { return "ERROR " + $_.Exception.Message }
}
function N($hex) { try { return [Convert]::ToInt64(("$hex" -replace '^0x',''),16) } catch { return -1 } }
function Tag($n) { return ('0x{0:x}' -f [int64]$n) }
function Utc($ts) { return [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }

$cache = @{}
function AddHeader($b) {
  $k = N $b.number
  $nh = ("$($b.nonce)" -replace '^0x','').PadLeft(16,'0')
  $cache[$k] = [pscustomobject]@{
    number = $k; time = (Utc (N $b.timestamp)); miner = ("$($b.miner)").ToLower()
    epoch = [Convert]::ToInt64($nh.Substring(0,8),16); round = [Convert]::ToInt64($nh.Substring(8,8),16)
  }
}
# Fetch block headers in JSON-RPC batches of 50 (falls back to single calls if batching fails).
function LoadHeaders($blocks) {
  $need = @($blocks | Where-Object { -not $cache.ContainsKey([int64]$_) } | Sort-Object -Unique)
  for ($i = 0; $i -lt $need.Count; $i += 50) {
    $chunk = $need[$i..([math]::Min($i + 49, $need.Count - 1))]
    $reqs = @(); $id = 0
    foreach ($n in $chunk) { $id++; $reqs += @{ jsonrpc='2.0'; id=$id; method='eth_getBlockByNumber'; params=@((Tag $n), $false) } }
    $body = ConvertTo-Json -InputObject @($reqs) -Depth 8 -Compress
    $ok = $false
    try {
      $resp = Invoke-RestMethod -Uri $RPC -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60
      foreach ($r in @($resp)) { if ($r.result) { AddHeader $r.result; $ok = $true } }
    } catch { $ok = $false }
    if (-not $ok) { foreach ($n in $chunk) { $b = Rpc 'eth_getBlockByNumber' @((Tag $n), $false); if ($b -ne $null -and "$b" -notlike 'ERROR*') { AddHeader $b } } }
    Write-Host ("    headers {0}/{1}" -f [math]::Min($i + 50, $need.Count), $need.Count)
  }
  foreach ($n in $need) {
    if (-not $cache.ContainsKey([int64]$n)) { $b = Rpc 'eth_getBlockByNumber' @((Tag $n), $false); if ($b -ne $null -and "$b" -notlike 'ERROR*') { AddHeader $b } }
  }
}
function ExpGet($url) {
  for ($t = 0; $t -lt 3; $t++) {
    try { return Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 40 } catch { Start-Sleep -Seconds 2 }
  }
  W ("  explorer ERROR on " + $url); return $null
}
# Explorer transactions from $startBlock going back until $minBlock.
function TxRange($startBlock, $minBlock) {
  $rows = @()
  $url = "$EXP/api/v2/transactions?filter=validated&block_number=$startBlock&index=0&items_count=50"
  for ($p = 0; $p -lt $MAXPAGES; $p++) {
    $r = ExpGet $url
    if ($r -eq $null -or $r.items -eq $null) { break }
    $stop = $false
    foreach ($it in $r.items) {
      $bn = $it.block_number; if ($bn -eq $null) { $bn = $it.block }
      if ([int64]$bn -lt $minBlock) { $stop = $true; continue }
      $to = ''; if ($it.to) { $to = ("$($it.to.hash)").ToLower() }
      $rows += [pscustomobject]@{ block = [int64]$bn; from = ("$($it.from.hash)").ToLower(); to = $to; method = "$($it.method)"; nonce = [int64]$it.nonce; hash = "$($it.hash)" }
    }
    Write-Host ("    explorer page {0}: {1} transactions so far" -f ($p + 1), $rows.Count)
    if ($stop -or $r.next_page_params -eq $null) { break }
    $q = ($r.next_page_params.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '&'
    $url = "$EXP/api/v2/transactions?filter=validated&$q"
  }
  return ,$rows
}

function Window($label, $startBlock, $minBlock) {
  W ''
  W ("== {0} (blocks {1} to {2}) ==" -f $label, $minBlock, $startBlock)
  $rows = TxRange $startBlock $minBlock
  if ($rows.Count -eq 0) { W '  no transactions'; return }
  LoadHeaders ($rows | ForEach-Object { $_.block })
  $full = @()
  foreach ($r in $rows) {
    $h = $cache[[int64]$r.block]
    if ($h -ne $null) { $full += [pscustomobject]@{ window = $label; block = $r.block; time_utc = $h.time; epoch = $h.epoch; round = $h.round; miner = $h.miner; from = $r.from; to = $r.to; method = $r.method; nonce = $r.nonce; hash = $r.hash } }
  }
  $full | Export-Csv -Path $csv -NoTypeInformation -Append -Encoding UTF8
  $s0 = $full | Sort-Object block | Select-Object -First 1; $s1 = $full | Sort-Object block | Select-Object -Last 1
  W ("  {0} transactions | {1} UTC (epoch {2}) to {3} UTC (epoch {4})" -f $full.Count, $s0.time_utc, $s0.epoch, $s1.time_utc, $s1.epoch)
  W '  block miner per transaction:'
  foreach ($g in @($full | Group-Object miner | Sort-Object Count -Descending)) { W ("     {0} : {1}" -f $g.Name, $g.Count) }
  $pairs = 0; $same = 0; $pairsD = 0; $sameD = 0
  foreach ($g in @($full | Group-Object from)) {
    $s = @($g.Group | Sort-Object nonce)
    for ($i = 1; $i -lt $s.Count; $i++) {
      if ($s[$i].nonce -eq ($s[$i-1].nonce + 1) -and $s[$i].epoch -eq $s[$i-1].epoch) {
        $pairs++; if ($s[$i].miner -eq $s[$i-1].miner) { $same++ }
        if ($s[$i].block -ne $s[$i-1].block) { $pairsD++; if ($s[$i].miner -eq $s[$i-1].miner) { $sameD++ } }
      }
    }
  }
  $pct = $(if ($pairsD -gt 0) { [math]::Round(100.0 * $sameD / $pairsD, 1) } else { 'n/a' })
  W ("  consecutive-nonce pairs, same sender, same epoch: {0} (same miner: {1})" -f $pairs, $same)
  W ("  of those in DIFFERENT blocks: {0}, same miner: {1} ({2} %)" -f $pairsD, $sameD, $pct)
}

W ''
W 'NOV WEEK 2 - STEP 1 (read-only): sender-affinity fork, full data run'
W ("run at {0} UTC" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
$head = N (Rpc 'eth_blockNumber' @())
W ("  chain head: block {0}" -f $head)

Window 'BEFORE (about 2 days before the fork)' ($FORK - 1) ($FORK - $SPAN)
Window 'AFTER (about 2 days after the fork)' ($FORK + $SPAN) $FORK
Window 'RECENT (about the last 24 hours)' $head ($head - 65000)

W ''
W '== Cross-check: block miner from the explorer vs from the RPC (30 random blocks from the data) =='
$data = Import-Csv $csv
$pick = @($data | Select-Object -ExpandProperty block -Unique | Get-Random -Count 30)
$match = 0; $checked = 0
foreach ($n in $pick) {
  $e = ExpGet "$EXP/api/v2/blocks/$n"
  if ($e -ne $null) {
    $checked++
    $em = ("$($e.miner.hash)").ToLower(); $rm = $cache[[int64]$n].miner
    if ($em -eq $rm) { $match++ } else { W ("  MISMATCH block {0}: explorer {1} vs RPC {2}" -f $n, $em, $rm) }
  }
}
W ("  {0} of {1} blocks: explorer miner = RPC miner" -f $match, $checked)
W ''
W 'Done. Data in step1-data.csv. Read-only: nothing was sent, nothing was signed.'
