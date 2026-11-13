# On-camera checker (read-only, offline): reads step1-data.csv and prints the numbers used in the post.
# Data source: public Rayls Public Chain RPC + explorer, collected by step1.ps1. All times UTC.
$ErrorActionPreference = 'Continue'
$data = Import-Csv (Join-Path $PSScriptRoot 'step1-data.csv')
foreach ($r in $data) { $r.block = [int64]$r.block; $r.nonce = [int64]$r.nonce; $r.epoch = [int64]$r.epoch }
$ORACLE = '0x339d413ccefd986b1b3647a9cfa9cbbe70a30749'
$LOG = Join-Path $PSScriptRoot ('check-output-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmm') + '-UTC.txt')
function Say($s) { Write-Host $s; Add-Content -Path $LOG -Value $s -Encoding UTF8 }
function Short($a) { return $a.Substring(0,8) }
Say ''
Say 'Rayls Public Chain: which validator includes a wallet''s transactions'
Say 'Fork SenderAffinityLoadBalancing at block 12,231,705 (10 Oct 2026 14:22:07 UTC)'
Say ('run at ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')

foreach ($w in @('BEFORE','AFTER','RECENT')) {
  $rows = @($data | Where-Object { $_.window -like "$w*" })
  $miners = @($rows | Select-Object -ExpandProperty miner -Unique).Count
  $pairs = 0; $same = 0
  foreach ($g in @($rows | Group-Object from)) {
    $s = @($g.Group | Sort-Object nonce)
    for ($i = 1; $i -lt $s.Count; $i++) {
      if ($s[$i].nonce -eq ($s[$i-1].nonce + 1) -and $s[$i].epoch -eq $s[$i-1].epoch -and $s[$i].block -ne $s[$i-1].block) {
        $pairs++; if ($s[$i].miner -eq $s[$i-1].miner) { $same++ }
      }
    }
  }
  $o = @($rows | Where-Object { $_.from -eq $ORACLE } | Sort-Object nonce)
  $bursts = 0; $one = 0; $cur = @($o[0])
  for ($i = 1; $i -le $o.Count; $i++) {
    $gap = 9999
    if ($i -lt $o.Count) { $gap = ([datetime]$o[$i].time_utc - [datetime]$o[$i-1].time_utc).TotalSeconds }
    if ($i -lt $o.Count -and $gap -le 60) { $cur += $o[$i] }
    else {
      if ($cur.Count -gt 1) { $bursts++; if (@($cur | Select-Object -ExpandProperty miner -Unique).Count -eq 1) { $one++ } }
      if ($i -lt $o.Count) { $cur = @($o[$i]) }
    }
  }
  $first = ($rows | Sort-Object block | Select-Object -First 1).time_utc; $last = ($rows | Sort-Object block | Select-Object -Last 1).time_utc
  Say ''
  Say ("== {0}: {1} to {2} UTC | {3} transactions | {4} validators ==" -f $w, $first, $last, $rows.Count, $miners)
  Say ("   next transaction from the same wallet, different block, SAME validator: {0} of {1} = {2} %   (chance: 1 in {3} = {4} %)" -f $same, $pairs, [math]::Round(100.0*$same/$pairs,1), $miners, [math]::Round(100.0/$miners,1))
  Say ("   oracle bursts (setPrice, 2+ transactions within 60 s) on ONE validator: {0} of {1} = {2} %" -f $one, $bursts, [math]::Round(100.0*$one/$bursts,1))
}

Say ''
Say '== Oracle wallet after the fork: which validator, and for how long =='
$o = @($data | Where-Object { $_.window -like 'AFTER*' -and $_.from -eq $ORACLE } | Sort-Object nonce)
$runs = @(); $start = $o[0]; $n = 1
for ($i = 1; $i -le $o.Count; $i++) {
  if ($i -lt $o.Count -and $o[$i].miner -eq $start.miner) { $n++ }
  else { $runs += [pscustomobject]@{ miner = $start.miner; block = $start.block; time = $start.time_utc; txs = $n }; if ($i -lt $o.Count) { $start = $o[$i]; $n = 1 } }
}
foreach ($r in ($runs | Select-Object -First 10)) { Say ("   {0}  from block {1}  {2} UTC  {3} transactions" -f (Short $r.miner), $r.block, $r.time, $r.txs) }
$a = $runs[1]; $b = $runs[$runs.Count - 1]
$steps = $runs.Count - 2
$mins = ([datetime]$b.time - [datetime]$a.time).TotalMinutes
Say ("   {0} handoffs between {1} and {2} UTC: {3} blocks and {4} minutes per handoff (code: OWNER_ROTATION_BLOCKS = 2048)" -f $steps, $a.time, $b.time, [math]::Round(($b.block - $a.block)/$steps), [math]::Round($mins/$steps,1))

Say ''
Say '== Last 24 hours: oracle wallet, every change of validator in order (first 18) =='
$o2 = @($data | Where-Object { $_.window -like 'RECENT*' -and $_.from -eq $ORACLE } | Sort-Object nonce)
$runs2 = @(); $start2 = $o2[0]; $n2 = 1
for ($i = 1; $i -le $o2.Count; $i++) {
  if ($i -lt $o2.Count -and $o2[$i].miner -eq $start2.miner) { $n2++ }
  else { $runs2 += [pscustomobject]@{ miner = $start2.miner; block = $start2.block; time = $start2.time_utc; txs = $n2 }; if ($i -lt $o2.Count) { $start2 = $o2[$i]; $n2 = 1 } }
}
foreach ($r in ($runs2 | Select-Object -First 18)) { Say ("   {0}  from block {1}  {2} UTC  {3} transactions" -f (Short $r.miner), $r.block, $r.time, $r.txs) }

Say ''
Say '== Last 24 hours: windows of the newest validator 0xbbd0b352 =='
$o = @($data | Where-Object { $_.window -like 'RECENT*' -and $_.from -eq $ORACLE } | Sort-Object nonce)
$nb = @($o | Where-Object { $_.miner -like '0xbbd0b352*' })
$clusters = @(); $c0 = $nb[0]; $c1 = $nb[0]
for ($i = 1; $i -le $nb.Count; $i++) {
  if ($i -lt $nb.Count -and ([datetime]$nb[$i].time_utc - [datetime]$c1.time_utc).TotalMinutes -le 40) { $c1 = $nb[$i] }
  else { $clusters += ,@($c0, $c1); if ($i -lt $nb.Count) { $c0 = $nb[$i]; $c1 = $nb[$i] } }
}
$tIn = 0; $tNew = 0
foreach ($c in $clusters) {
  $in = @($o | Where-Object { $_.block -ge $c[0].block -and $_.block -le $c[1].block })
  $byNew = @($in | Where-Object { $_.miner -like '0xbbd0b352*' }).Count
  $tIn += $in.Count; $tNew += $byNew
  $g = $in | Where-Object { $_.miner -notlike '0xbbd0b352*' } | Group-Object miner | Sort-Object Count -Descending | Select-Object -First 1
  $other = $(if ($g) { "{0}: {1}" -f (Short $g.Name), $g.Count } else { 'none' })
  Say ("   {0} to {1} UTC: oracle transactions {2} | by 0xbbd0b3: {3} | by next validator {4}" -f $c[0].time_utc, $c[1].time_utc, $in.Count, $byNew, $other)
}
Say ("   total: {0} oracle transactions | by 0xbbd0b3: {1} | by another validator: {2}" -f $tIn, $tNew, ($tIn - $tNew))
Say ''
Say 'Read-only. Nothing was sent, nothing was signed.'
