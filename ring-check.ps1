# Nov Week 2, ring check (read-only, zero cost). Public RPC and explorer only. All times UTC.
# 1. Reads this epoch's committee and BLS keys from the ConsensusRegistry contract.
# 2. Rebuilds the ring the code walks: authorities sorted by id, id = BLAKE3(BLS public key)
#    (committee.rs derive_id, sealed_batch.rs CommitteeSlots, txn_forwarder.rs).
# 3. Compares that ring with the order seen on chain in step1-data.csv.
# 4. Predicts the price wallet's validator now: (FxHash(sender) + header / 2048) mod committee size
#    (txn_forwarder.rs lines 397-401), and checks it against the wallet's latest transactions.
param([string]$Wallet = '')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'
$LOG = Join-Path $PSScriptRoot ('ring-output-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmm') + '-UTC.txt')
function Say($s) { Write-Host $s; Add-Content -Path $LOG -Value $s -Encoding UTF8 }

if (-not ('RaylsHash' -as [type])) {
Add-Type -TypeDefinition @'
using System;
public static class RaylsHash
{
    // rustc-hash 2.1.2 FxHasher: default() then write(bytes) then finish()
    static ulong MulMix(ulong x, ulong y)
    {
        unchecked
        {
            ulong xl = x & 0xFFFFFFFFUL, xh = x >> 32, yl = y & 0xFFFFFFFFUL, yh = y >> 32;
            ulong ll = xl * yl, lh = xl * yh, hl = xh * yl, hh = xh * yh;
            ulong mid = (ll >> 32) + (lh & 0xFFFFFFFFUL) + (hl & 0xFFFFFFFFUL);
            ulong lo = (ll & 0xFFFFFFFFUL) | (mid << 32);
            ulong hi = hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
            return lo ^ hi;
        }
    }
    static ulong Le64(byte[] b, int o) { ulong v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | b[o + i]; return v; }
    static ulong Le32(byte[] b, int o) { ulong v = 0; for (int i = 3; i >= 0; i--) v = (v << 8) | b[o + i]; return v; }
    static ulong HashBytes(byte[] bytes)
    {
        unchecked
        {
            int len = bytes.Length;
            ulong s0 = 0x243f6a8885a308d3UL, s1 = 0x13198a2e03707344UL;
            if (len <= 16)
            {
                if (len >= 8) { s0 ^= Le64(bytes, 0); s1 ^= Le64(bytes, len - 8); }
                else if (len >= 4) { s0 ^= Le32(bytes, 0); s1 ^= Le32(bytes, len - 4); }
                else if (len > 0) { s0 ^= bytes[0]; s1 ^= ((ulong)bytes[len - 1] << 8) | bytes[len / 2]; }
            }
            else
            {
                int bulk = len - 1; int off = 0;
                while (bulk - off >= 16)
                {
                    ulong x = Le64(bytes, off), y = Le64(bytes, off + 8);
                    ulong t = MulMix(s0 ^ x, 0xa4093822299f31d0UL ^ y);
                    s0 = s1; s1 = t; off += 16;
                }
                s0 ^= Le64(bytes, len - 16); s1 ^= Le64(bytes, len - 8);
            }
            return MulMix(s0, s1) ^ (ulong)len;
        }
    }
    public static ulong FxSlotDigest(byte[] input)
    {
        unchecked
        {
            ulong h = 0; ulong K = 0xf1357aea2e62a9c5UL;
            h = (h + HashBytes(input)) * K;
            return (h << 26) | (h >> 38);
        }
    }
    // BLAKE3, single chunk (input up to 1024 bytes), 32-byte output
    static readonly uint[] IV = { 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };
    static readonly int[] PERM = { 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };
    static uint Rotr(uint x, int n) { return (x >> n) | (x << (32 - n)); }
    static void G(uint[] s, int a, int b, int c, int d, uint mx, uint my)
    {
        unchecked
        {
            s[a] = s[a] + s[b] + mx; s[d] = Rotr(s[d] ^ s[a], 16);
            s[c] = s[c] + s[d]; s[b] = Rotr(s[b] ^ s[c], 12);
            s[a] = s[a] + s[b] + my; s[d] = Rotr(s[d] ^ s[a], 8);
            s[c] = s[c] + s[d]; s[b] = Rotr(s[b] ^ s[c], 7);
        }
    }
    static uint[] Compress(uint[] cv, uint[] m, ulong counter, uint blockLen, uint flags)
    {
        uint[] s = { cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7], IV[0], IV[1], IV[2], IV[3],
                     (uint)(counter & 0xFFFFFFFF), (uint)(counter >> 32), blockLen, flags };
        uint[] w = (uint[])m.Clone();
        for (int r = 0; r < 7; r++)
        {
            G(s, 0, 4, 8, 12, w[0], w[1]); G(s, 1, 5, 9, 13, w[2], w[3]);
            G(s, 2, 6, 10, 14, w[4], w[5]); G(s, 3, 7, 11, 15, w[6], w[7]);
            G(s, 0, 5, 10, 15, w[8], w[9]); G(s, 1, 6, 11, 12, w[10], w[11]);
            G(s, 2, 7, 8, 13, w[12], w[13]); G(s, 3, 4, 9, 14, w[14], w[15]);
            if (r < 6) { uint[] p = new uint[16]; for (int i = 0; i < 16; i++) p[i] = w[PERM[i]]; w = p; }
        }
        for (int i = 0; i < 8; i++) { s[i] ^= s[i + 8]; s[i + 8] ^= cv[i]; }
        return s;
    }
    public static byte[] Blake3(byte[] input)
    {
        if (input.Length > 1024) throw new ArgumentException("input over 1024 bytes not supported");
        uint[] cv = (uint[])IV.Clone();
        int blocks = Math.Max(1, (input.Length + 63) / 64);
        uint[] outw = null;
        for (int bi = 0; bi < blocks; bi++)
        {
            int start = bi * 64; int blen = Math.Min(64, input.Length - start); if (blen < 0) blen = 0;
            byte[] blk = new byte[64]; Array.Copy(input, start, blk, 0, blen);
            uint[] m = new uint[16]; for (int i = 0; i < 16; i++) m[i] = (uint)Le32(blk, i * 4);
            uint flags = 0; if (bi == 0) flags |= 1; if (bi == blocks - 1) flags |= 2 | 8;
            uint[] s = Compress(cv, m, 0, (uint)blen, flags);
            if (bi == blocks - 1) outw = s; else { cv = new uint[8]; Array.Copy(s, cv, 8); }
        }
        byte[] o = new byte[32];
        for (int i = 0; i < 8; i++) { o[4 * i] = (byte)outw[i]; o[4 * i + 1] = (byte)(outw[i] >> 8); o[4 * i + 2] = (byte)(outw[i] >> 16); o[4 * i + 3] = (byte)(outw[i] >> 24); }
        return o;
    }
    public static int OwnerSlot(byte[] sender, long header, int size)
    {
        unchecked
        {
            ulong window = (ulong)(header / 2048);
            ulong v = FxSlotDigest(sender) + window;
            return (int)(v % (ulong)size);
        }
    }
    public static int SenderSlot(byte[] sender, int size) { return (int)(FxSlotDigest(sender) % (ulong)size); }
    public static long Window(long header) { return header / 2048; }
    public static byte[] FromHex(string h)
    {
        if (h.StartsWith("0x")) h = h.Substring(2);
        byte[] b = new byte[h.Length / 2];
        for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(h.Substring(2 * i, 2), 16);
        return b;
    }
    public static string ToHex(byte[] b) { return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant(); }
}
'@
}

$RPC = 'https://mainnet-rpc.rayls.com'
$EXP = 'https://explorer.rayls.com'
$REG = '0x07e17e17e17e17e17e17e17e17e17e17e17e17e1'
$ORACLE = '0x339d413ccefd986b1b3647a9cfa9cbbe70a30749'

function Rpc($method, $params) {
  $body = @{ jsonrpc='2.0'; id=1; method=$method; params=$params } | ConvertTo-Json -Depth 8 -Compress
  try { $r = Invoke-RestMethod -Uri $RPC -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
        if ($r.error) { return "ERROR " + ($r.error | ConvertTo-Json -Compress) } ; return $r.result }
  catch { return "ERROR " + $_.Exception.Message }
}
function N($hex) { try { return [Convert]::ToInt64(("$hex" -replace '^0x',''),16) } catch { return -1 } }
function Tag($n) { return ('0x{0:x}' -f [int64]$n) }
function Utc($ts) { return [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }
function Hx($v) { return ("$v" -replace '^0x','') }
function U($h, $o) { return [Convert]::ToInt64($h.Substring(2 * $o + 48, 16), 16) }
function Pad($n) { return ('{0:x}' -f [int64]$n).PadLeft(64, '0') }
function Call($data) { return Rpc 'eth_call' @(@{ to = $REG; data = $data }, 'latest') }
function Short($a) { return $a.Substring(0, 10) }
function ExpGet($url) {
  for ($t = 0; $t -lt 3; $t++) { try { return Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 40 } catch { Start-Sleep -Seconds 2 } }
  return $null
}
function DecodeValidators($res) {
  $h = Hx $res
  $arr = U $h 0
  $n = U $h $arr
  $base = $arr + 32
  $list = @()
  for ($i = 0; $i -lt $n; $i++) {
    $t = $base + (U $h ($base + 32 * $i))
    $bo = U $h $t
    $addr = ('0x' + $h.Substring(2 * ($t + 32) + 24, 40)).ToLower()
    $blen = U $h ($t + $bo)
    $key = $h.Substring(2 * ($t + $bo + 32), 2 * $blen)
    $list += [pscustomobject]@{ addr = $addr; key = $key; keylen = $blen; id = '' }
  }
  return $list
}

Say ''
Say 'Rayls Public Chain: the validator ring, rebuilt from the registry and the code'
Say ('run at ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')

# 1. committee and keys
$epoch = U (Hx (Call '0xb97dd9e2')) 0
$res = Call ('0xa0201be5' + (Pad $epoch))
if ("$res" -like 'ERROR*') { Say ('   getCommitteeValidators failed: ' + $res); $res = Call ('0x8cc05eda' + (Pad 3)) }
$vals = @(DecodeValidators $res)
Say ''
Say ("== ConsensusRegistry {0}, epoch {1}: {2} committee validators ==" -f $REG, $epoch, $vals.Count)
foreach ($v in $vals) { $v.id = [RaylsHash]::ToHex([RaylsHash]::Blake3([RaylsHash]::FromHex($v.key))) }
$ids = New-Object 'System.Collections.Generic.List[string]'
foreach ($v in $vals) { $ids.Add($v.id) }
$ids.Sort([StringComparer]::Ordinal)
$ring = @()
foreach ($id in $ids) { $ring += @($vals | Where-Object { $_.id -eq $id })[0] }
Say '   slot  authority id = BLAKE3(BLS key)   BLS key bytes   validator (block miner)'
for ($i = 0; $i -lt $ring.Count; $i++) {
  Say ("   {0,4}  0x{1}...       {2,3}             {3}" -f $i, $ring[$i].id.Substring(0, 16), $ring[$i].keylen, $ring[$i].addr)
}
$ringAddrs = @($ring | ForEach-Object { $_.addr })
Say ('   ring order from the code: ' + (($ringAddrs | ForEach-Object { Short $_ }) -join ' -> ') + ' -> (back to start)')

# 2. order seen on chain
$data = Import-Csv (Join-Path $PSScriptRoot 'step1-data.csv')
function FirstSeen($w) {
  $o = @($data | Where-Object { $_.window -like "$w*" -and $_.from -eq $ORACLE } | Sort-Object { [int64]$_.nonce })
  $seen = @()
  foreach ($r in $o) { if ($seen -notcontains $r.miner) { $seen += $r.miner } }
  return $seen
}
function SameCycle($obs, $ra) {
  $r = @($ra | Where-Object { $obs -contains $_ })
  if ($r.Count -ne $obs.Count) { return 'NO (different validators)' }
  $k = [array]::IndexOf($r, $obs[0])
  for ($i = 0; $i -lt $obs.Count; $i++) { if ($r[($k + $i) % $r.Count] -ne $obs[$i]) { return 'NO' } }
  return 'YES'
}
Say ''
Say '== Order in which the price wallet met each validator (step1-data.csv) =='
foreach ($w in @('AFTER', 'RECENT')) {
  $obs = @(FirstSeen $w)
  Say ("   {0,-6} {1}" -f $w, (($obs | ForEach-Object { Short $_ }) -join ' -> '))
  Say ("          same cyclic order as the ring from the code: {0}" -f (SameCycle $obs $ringAddrs))
}

# 3. live position on the ring (rayls_latestHeader returns "Internal error" on the public RPC, so the window is read
#    from the price wallet's own hand-offs instead of from the consensus header number)
function TxsFrom($addr, $pages) {
  $all = @(); $url = "$EXP/api/v2/addresses/$addr/transactions?filter=from"
  for ($p = 0; $p -lt $pages; $p++) {
    $r = ExpGet $url
    if ($r -eq $null -or $r.items -eq $null) { break }
    foreach ($it in $r.items) {
      $bn = $it.block_number; if ($bn -eq $null) { $bn = $it.block }
      if ($bn -ne $null -and [int64]$bn -gt 0) { $all += [pscustomobject]@{ block = [int64]$bn; nonce = [int64]$it.nonce; miner = ''; time = '' } }
    }
    if ($r.next_page_params -eq $null) { break }
    $q = ($r.next_page_params.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '&'
    $url = "$EXP/api/v2/addresses/$addr/transactions?filter=from&$q"
  }
  return $all
}
function FillMiners($txs) {
  $map = @{}
  $u = @($txs | ForEach-Object { $_.block } | Sort-Object -Unique)
  for ($i = 0; $i -lt $u.Count; $i += 50) {
    $chunk = $u[$i..([math]::Min($i + 49, $u.Count - 1))]
    $reqs = @(); $id = 0
    foreach ($n in $chunk) { $id++; $reqs += @{ jsonrpc = '2.0'; id = $id; method = 'eth_getBlockByNumber'; params = @((Tag $n), $false) } }
    $body = ConvertTo-Json -InputObject @($reqs) -Depth 8 -Compress
    try {
      $resp = Invoke-RestMethod -Uri $RPC -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60
      foreach ($r in @($resp)) { if ($r.result) { $map[[int64](N $r.result.number)] = $r.result } }
    } catch { }
  }
  foreach ($n in $u) { if (-not $map.ContainsKey([int64]$n)) { $b = Rpc 'eth_getBlockByNumber' @((Tag $n), $false); if ($b -ne $null -and "$b" -notlike 'ERROR*') { $map[[int64]$n] = $b } } }
  foreach ($t in $txs) { $b = $map[[int64]$t.block]; if ($b -ne $null) { $t.miner = ("$($b.miner)").ToLower(); $t.time = Utc (N $b.timestamp) } }
}
function SlotOf($a) { return [array]::IndexOf($ringAddrs, $a) }

Say ''
Say '== Where the price wallet is on the ring right now =='
$size = $ring.Count
$head = N (Rpc 'eth_blockNumber' @())
$bh = Rpc 'eth_getBlockByNumber' @((Tag $head), $false)
$b0 = Rpc 'eth_getBlockByNumber' @((Tag ($head - 2048)), $false)
$spb = ((N $bh.timestamp) - (N $b0.timestamp)) / 2048.0
Say ("   chain head block {0} at {1} UTC, last 2048 blocks took {2:N2} s per block" -f $head, (Utc (N $bh.timestamp)), $spb)
$ox = @(TxsFrom $ORACLE 2 | Sort-Object block -Descending)
FillMiners $ox
$oNat = [RaylsHash]::SenderSlot([RaylsHash]::FromHex($ORACLE), $size)
Say ("   price wallet natural slot = FxHash mod {0} = {1}" -f $size, $oNat)
Say '   latest price updates (newest first):'
foreach ($t in ($ox | Select-Object -First 12)) { Say ("     block {0}  {1} UTC  nonce {2}  included by {3}  (slot {4})" -f $t.block, $t.time, $t.nonce, (Short $t.miner), (SlotOf $t.miner)) }
$clean = $false; $k = -1; $eta = $null; $left = 0
if ($ox.Count -gt 0) {
  $cur = $ox[0].miner; $cs = SlotOf $cur
  $pred = $ringAddrs[($cs + $size - 1) % $size]
  $mixed = $false; $seenOther = $false
  foreach ($t in ($ox | Select-Object -First 15)) {
    if ($t.miner -ne $cur) { $seenOther = $true; if ($t.miner -ne $pred) { $mixed = $true } }
    elseif ($seenOther) { $mixed = $true }
  }
  $start = $null
  foreach ($t in $ox) { if ($t.miner -eq $cur) { $start = $t } elseif ($t.miner -eq $pred) { break } }
  $k = ($cs - $oNat + $size) % $size
  Say ("   now on slot {0} ({1}), so the window number mod {2} = ({0} - {3}) mod {2} = {4}" -f $cs, (Short $cur), $size, $oNat, $k)
  if ($start -ne $null) {
    $nb = $start.block + 2055
    $left = ($nb - $head) * $spb / 60
    $eta = [DateTime]::UtcNow.AddMinutes($left)
    Say ("   this window began by block {0} ({1} UTC); next hand-off expected near block {2}, in about {3:N0} minutes (around {4} UTC), to slot {5} -> {6}" -f $start.block, $start.time, $nb, $left, $eta.ToString('HH:mm'), (($cs + 1) % $size), (Short $ringAddrs[($cs + 1) % $size]))
  }
  if ($mixed) { Say '   the last 15 updates are split between validators (newest validator''s window or failover): wait for the next window' }
  $clean = (-not $mixed) -and ($start -ne $null) -and ($left -gt 10) -and (($head - $start.block) * $spb / 60 -gt 2)
}

if ($Wallet -ne '') {
  $w = $Wallet.ToLower()
  $wNat = [RaylsHash]::SenderSlot([RaylsHash]::FromHex($w), $size)
  $d = ($wNat - $oNat + $size) % $size
  Say ''
  Say ("== My wallet {0} ==" -f $w)
  Say ("   FxHash = {0}, natural slot = FxHash mod {1} = {2}, so it sits {3} slots after the price wallet on the ring" -f [RaylsHash]::FxSlotDigest([RaylsHash]::FromHex($w)), $size, $wNat, $d)
  if ($k -ge 0) {
    $now = ($wNat + $k) % $size
    Say ("   owner now = ({0} + {1}) mod {2} = slot {3} -> {4}; after the next hand-off -> {5}" -f $wNat, $k, $size, $now, $ringAddrs[$now], $ringAddrs[($now + 1) % $size])
    if ($clean) { Say ("   SEND NOW (window has about {0:N0} minutes left): my transactions should be included by {1}" -f $left, $ringAddrs[$now]) }
    else { Say '   WAIT: too close to a hand-off or the window is split; run again in a few minutes' }
  }
  $mx = @(TxsFrom $w 1 | Sort-Object block -Descending | Select-Object -First 6)
  FillMiners $mx
  if ($mx.Count -gt 0) {
    Say '   my latest transactions, who included them, and who the code predicts:'
    foreach ($t in $mx) {
      $near = @($ox | Where-Object { [math]::Abs($_.block - $t.block) -le 400 })
      $ms = @($near | ForEach-Object { $_.miner } | Sort-Object -Unique)
      if ($near.Count -eq 0) { Say ("     block {0}  {1} UTC  nonce {2}  included by {3}  (no price update within 400 blocks, not checked)" -f $t.block, $t.time, $t.nonce, (Short $t.miner)); continue }
      $ref = @($near | Where-Object { $_.block -le $t.block } | Sort-Object block -Descending)
      if ($ref.Count -eq 0) { $ref = @($near | Sort-Object block) }
      $p = $ringAddrs[((SlotOf $ref[0].miner) + $d) % $size]
      $ok = 'MATCH'; if ($p -ne $t.miner) { $ok = 'different' }
      $note = ''; if ($ms.Count -gt 1) { $note = '  (price wallet changed validator within 400 blocks)' }
      Say ("     block {0}  {1} UTC  nonce {2}  included by {3}  predicted {4}  {5}{6}" -f $t.block, $t.time, $t.nonce, (Short $t.miner), (Short $p), $ok, $note)
    }
  }
}
Say ''
Say 'Read-only. Nothing was sent, nothing was signed.'
