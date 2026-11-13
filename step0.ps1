# Nov Week 2, STEP 0 (read-only). Does the SenderAffinityLoadBalancing fork show up in public chain data?
# No wallet, no transactions, zero cost. Only public RPC and explorer reads. All times printed in UTC.
# Code basis (axyl commit c2a4ee604a9d735ef20409b12e4047b8137d3632):
#   schedule.rs line 120: SenderAffinityLoadBalancing at mainnet block 12,231,705
#   validator.rs line 337: "Key the slot on the sender so one validator owns a sender's whole nonce chain"
#   output.rs line 28: the batch author's address "is used as the block beneficiary during execution"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'step0-results.txt'
$csv = Join-Path $PSScriptRoot 'step0-sample.csv'
"" | Set-Content $out -Encoding UTF8
if (Test-Path $csv) { Remove-Item $csv }
function W($s) { $s | Add-Content $out -Encoding UTF8; Write-Host $s }

$RPC   = 'https://mainnet-rpc.rayls.com'
$EXP   = 'https://explorer.rayls.com'
$FORK  = 12231705
$AFTER_START = $FORK + 20000
$PAGES = 4

function Rpc($method, $params) {
  $body = @{ jsonrpc='2.0'; id=1; method=$method; params=$params } | ConvertTo-Json -Depth 8 -Compress
  try { $r = Invoke-RestMethod -Uri $RPC -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 25
        if ($r.error) { return "ERROR " + ($r.error | ConvertTo-Json -Compress) } ; return $r.result }
  catch { return "ERROR " + $_.Exception.Message }
}
function N($hex) { try { return [Convert]::ToInt64(("$hex" -replace '^0x',''),16) } catch { return -1 } }
function Tag($n) { return ('0x{0:x}' -f [int64]$n) }
function Utc($ts) { return [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }

$cache = @{}
function Header($n) {
  $k = [int64]$n
  if ($cache.ContainsKey($k)) { return $cache[$k] }
  $b = Rpc 'eth_getBlockByNumber' @((Tag $k), $false)
  if ($b -eq $null -or "$b" -like 'ERROR*') { return $null }
  $nh = ("$($b.nonce)" -replace '^0x','').PadLeft(16,'0')
  $h = [pscustomobject]@{
    number = $k
    time   = (Utc (N $b.timestamp))
    miner  = ("$($b.miner)").ToLower()
    epoch  = [Convert]::ToInt64($nh.Substring(0,8),16)
    round  = [Convert]::ToInt64($nh.Substring(8,8),16)
    txs    = @($b.transactions).Count
  }
  $cache[$k] = $h
  return $h
}
function ExpGet($url) { try { return Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 } catch { W ("  explorer ERROR " + $_.Exception.Message); return $null } }

function TxPages($startBlock, $pages) {
  $rows = @()
  $url = "$EXP/api/v2/transactions?filter=validated&block_number=$startBlock&index=0&items_count=50"
  for ($p = 0; $p -lt $pages; $p++) {
    $r = ExpGet $url
    if ($r -eq $null -or $r.items -eq $null) { W "  explorer page $p : no data"; break }
    foreach ($it in $r.items) {
      $bn = $it.block_number; if ($bn -eq $null) { $bn = $it.block }
      $rows += [pscustomobject]@{ block = [int64]$bn; from = ("$($it.from.hash)").ToLower(); nonce = [int64]$it.nonce; hash = "$($it.hash)" }
    }
    if ($r.next_page_params -eq $null) { break }
    $q = ($r.next_page_params.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '&'
    $url = "$EXP/api/v2/transactions?filter=validated&$q"
  }
  return ,$rows
}

function Analyse($label, $rows) {
  W ''
  W ("== {0} ==" -f $label)
  if ($rows.Count -eq 0) { W '  no transactions'; return [pscustomobject]@{ miners = 0; pairs = 0; same = 0 } }
  $lo = ($rows | Measure-Object block -Minimum).Minimum; $hi = ($rows | Measure-Object block -Maximum).Maximum
  W ("  {0} transactions from explorer, blocks {1} to {2}" -f $rows.Count, $lo, $hi)
  $full = @()
  foreach ($r in $rows) {
    $h = Header $r.block
    if ($h -ne $null) {
      $full += [pscustomobject]@{ side = $label; block = $r.block; time_utc = $h.time; epoch = $h.epoch; miner = $h.miner; from = $r.from; nonce = $r.nonce; hash = $r.hash }
    }
  }
  $full | Export-Csv -Path $csv -NoTypeInformation -Append -Encoding UTF8
  $lt = ($full | Sort-Object block | Select-Object -First 1).time_utc; $ht = ($full | Sort-Object block | Select-Object -Last 1).time_utc
  W ("  time range (block headers): {0} UTC to {1} UTC" -f $lt, $ht)
  W '  block miner (beneficiary) per transaction:'
  $mg = @($full | Group-Object miner | Sort-Object Count -Descending)
  foreach ($g in $mg) { W ("     {0} : {1}" -f $g.Name, $g.Count) }
  W '  busiest senders:'
  foreach ($g in @($full | Group-Object from | Sort-Object Count -Descending | Select-Object -First 5)) { W ("     {0} : {1} txs" -f $g.Name, $g.Count) }
  $pairs = 0; $same = 0
  foreach ($g in @($full | Group-Object from)) {
    $s = @($g.Group | Sort-Object nonce)
    for ($i = 1; $i -lt $s.Count; $i++) {
      if ($s[$i].nonce -eq ($s[$i-1].nonce + 1) -and $s[$i].epoch -eq $s[$i-1].epoch) {
        $pairs++
        if ($s[$i].miner -eq $s[$i-1].miner) { $same++ }
      }
    }
  }
  $pct = $(if ($pairs -gt 0) { [math]::Round(100.0 * $same / $pairs, 1) } else { 'n/a' })
  W ("  consecutive-nonce pairs from the same sender, same epoch: {0}" -f $pairs)
  W ("  of those, included by the SAME block miner: {0} ({1} %)" -f $same, $pct)
  return [pscustomobject]@{ miners = $mg.Count; pairs = $pairs; same = $same }
}

W ''
W 'NOV WEEK 2 - STEP 0 (read-only): sender-affinity fork check'
W ("run at {0} UTC" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))

W ''
W '== 1. Chain head =='
$hn = N (Rpc 'eth_blockNumber' @())
$hh = Header $hn
if ($hh) { W ("  block {0} | {1} UTC | epoch {2} | miner {3}" -f $hh.number, $hh.time, $hh.epoch, $hh.miner) } else { W '  head ERROR' }

W ''
W '== 2. Fork blocks from the node schedule (axyl c2a4ee6, schedule.rs lines 111-121) =='
foreach ($p in @(@(893558,'TransactionLoadBalancing'), @(12231705,'OutputSeqNormalization + SenderAffinityLoadBalancing'), @(13832605,'Eip161EmptyAccountGuard'))) {
  $h = Header $p[0]
  if ($h) { W ("  {0} | {1} UTC | epoch {2} round {3} | miner {4} | txs {5} | {6}" -f $h.number, $h.time, $h.epoch, $h.round, $h.miner, $h.txs, $p[1]) }
  else { W ("  {0} | could not read | {1}" -f $p[0], $p[1]) }
}

W ''
W '== 3. Explorer sample before and after block 12,231,705 =='
$before = TxPages ($FORK - 1) $PAGES
$afterAll = TxPages $AFTER_START $PAGES
$after  = @($afterAll | Where-Object { $_.block -ge $FORK })
$pagingOk = ($before.Count -gt 0) -and (($before | Measure-Object block -Maximum).Maximum -lt $FORK)
W ("  explorer block_number paging honoured: {0}" -f $pagingOk)
$a = Analyse 'BEFORE fork (blocks below 12,231,705)' $before
$b = Analyse 'AFTER fork (blocks from 12,231,705)' $after

W ''
W '== 4. STEP 0 verdict =='
W ("  [{0}] explorer paging by block works" -f $(if ($pagingOk) { 'PASS' } else { 'FAIL' }))
W ("  [{0}] block miner varies (distinct miners before: {1}, after: {2})" -f $(if ($a.miners -ge 3 -or $b.miners -ge 3) { 'PASS' } else { 'FAIL' }), $a.miners, $b.miners)
W ("  [{0}] enough same-sender consecutive pairs (before: {1}, after: {2}; need 10+ each)" -f $(if ($a.pairs -ge 10 -and $b.pairs -ge 10) { 'PASS' } else { 'CHECK' }), $a.pairs, $b.pairs)
W ''
W 'Sample rows saved in step0-sample.csv. Read-only: nothing was sent, nothing was signed.'
