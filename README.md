# Can one validator hold up your wallet's transactions? A check of sender affinity on the Rayls Public Chain

Checked on 12 Nov 2026 (all times UTC). Public RPC (`https://mainnet-rpc.rayls.com`, chainId 72957), the Blockscout explorer API (`explorer.rayls.com`) and the ConsensusRegistry contract. Everything is read-only except three zero-value transfers from my own test wallet.

## Short answer

- Since block **12,231,705** (10 Oct 2026 14:22:07 UTC, the `SenderAffinityLoadBalancing` upgrade), a wallet's transactions mostly go to **one validator at a time**.
- When a wallet's next transaction (next nonce, same epoch) landed in a different block, the same validator included it:
  **14.4 %** before (177 of 1,227; chance with 7 validators is 14.3 %), **91.4 %** after (1,080 of 1,181), **87.9 %** on 11 to 12 Nov with 8 validators (886 of 1,008). In 3-hour bins: 10.7 % just before the block, 91.5 % just after.
- The owner rotates: the price-feed wallet `0x339d…0749` changed validator **62 times** between 10 Oct 14:57 and 12 Oct 13:57 UTC, one hand-off every **2,055 blocks, 45.5 minutes**. The code constant is `OWNER_ROTATION_BLOCKS = 2048` executed anchors.
- The ring order is not published. Rebuilt from the registry (validators sorted by BLAKE3 of their BLS key, as the code does), it matches the order seen on chain in October (7 validators) and November (8).
- Live test: at 22:54:48 UTC on 12 Nov, `ring-check.ps1` predicted that my test wallet `0x6f97…e9a2` would be served by `0x0808…41bc7`. Three zero-value transfers at 22:59 UTC landed in blocks 14,376,417, 14,376,426 and 14,376,436, all mined by `0x0808…41bc7`.

## Documented, independently verified, my analysis, not verified

| | |
|---|---|
| Documented | axyl at commit `c2a4ee6`: the slot is keyed on the sender after the upgrade (`fork.rs` L44-47, `validator.rs` L324-348); the observer's transaction forwarder rotates each sender's owner one slot every 2,048 executed anchors, "so a dishonest owner can withhold a sender's transactions for at most one window" (`txn_forwarder.rs` L67-71, L388-402); it skips a validator it is not connected to and waits `SUBMIT_TIMEOUT` = 5 s for one that does not answer (L46-47, L470-477); slots are ordered by authority id = BLAKE3(BLS key) (`sealed_batch.rs` L219-235, `committee.rs` L118-124). The `mainnet-v1.4.1` tag (2 Oct 2026) set block 12,231,705 and estimated 8 Oct 13:00 UTC at 0.697 s per block. |
| Independently verified (this repo) | The same-validator shares above, before vs after the block, for the price-feed wallet and for other wallets (12.4 % to 94.3 % for pairs at most 1,000 blocks apart); 62 hand-offs; the ring order rebuilt from the registry matches the chain; the live prediction for my own wallet; the block came on 10 Oct 14:22:07 UTC with about 1.33 s per block, not 0.697 s. |
| My analysis | On the newest validator's 4 turns (`0xbbd0…9662`, slot 2), 54 of 152 price updates went to the next slot (`0xc2af…0fe6`), often mid-burst. Bursts on its turns still finished within 6 s (3.26 s on average vs 2.95 s on other turns, max 12 s), and every switch inside a burst came within 4 s. That fits the forwarder's "not connected, go to the next validator" path, not the 5 s timeout. |
| Not verified | Whether a validator can actually withhold transactions (not tested). Why `0xbbd0` was skipped. The consensus header number: `rayls_latestHeader` returns `{"code":-32603,"message":"Internal error"}` on the public RPC, so the window is read from the price-feed wallet's hand-offs. My test wallet shares the price-feed wallet's ring slot (5), so its prediction is not independent of that wallet. |

## Files

- `step0.ps1`, `RUN-STEP0.bat`, `step0-results.txt`, `step0-sample.csv`: first feasibility check (miner field, explorer paging, a small sample either side of the block).
- `step1.ps1`, `RUN-STEP1.bat`, `step1-results.txt`, `step1-data.csv`: the full collection, 5,826 transactions with block, time, epoch, round, miner, sender, receiver, method, nonce, hash. Windows: 8 Oct 14:22 to 10 Oct 14:17, 10 Oct 14:22 to 12 Oct 14:17, 11 Nov 18:40 to 12 Nov 18:46 UTC. Explorer miner = RPC miner on 30 of 30 random blocks.
- `check-affinity.ps1`, `RUN-CHECK.bat`, `check-output-20261112-2100-UTC.txt`: the offline checker shown in the video (reads `step1-data.csv`).
- `ring-check.ps1`, `RUN-RING.bat`: reads the committee from the ConsensusRegistry (`getCommitteeValidators`), rebuilds the ring, compares it with the chain, and predicts a wallet's validator (`-Wallet 0x…`). Its FxHash and BLAKE3 code was checked against the Rust crates the node uses (rustc-hash 2.1.2, blake3) on 46 test vectors, including the pinned value in `validator.rs`.
- `ring-output-20261112-2254-UTC.txt`: the prediction for my test wallet before sending. `ring-output-20261112-2305-UTC.txt`: the same wallet after the transfers (MATCH x6; the three at 22:31 were checked after the fact).
- `ring-output-20261112-2203-UTC.txt`, `-2217-`, `-2224-`, `-2239-`: earlier runs (ring only, and predictions for a second wallet `0xb547…5c30` that I did not test, because the transfers of that round were sent from the test wallet).
- `extra-stats.py`, `extra-stats-output.txt`: the 3-hour bins, the other-wallet shares and the newest-validator numbers (Python 3, standard library).

## Addresses

| What | Address |
|---|---|
| ConsensusRegistry | 0x07e17e17e17e17e17e17e17e17e17e17e17e17e1 |
| Price-feed wallet (setPrice to PriceFeed) | 0x339d413ccefd986b1b3647a9cfa9cbbe70a30749 |
| My test wallet | 0x6f97e65f95a893e06a040a5200fd9493880ae9a2 |
| Newest validator (epoch 197, slot 2) | 0xbbd0b35294fff3981a7aeb2adb14f23f93bf9662 |

## Sources

- axyl code: https://github.com/raylsnetwork/axyl/tree/c2a4ee604a9d735ef20409b12e4047b8137d3632
- Activation estimate: https://github.com/raylsnetwork/axyl/commit/6909618
- Ethereum block proposal: https://ethereum.org/en/developers/docs/consensus-mechanisms/pos/block-proposal/
- EIP-7805 (FOCIL, draft): https://eips.ethereum.org/EIPS/eip-7805
- Anza, transaction landing on Solana: https://www.anza.xyz/blog/transaction-landing-on-tpu
