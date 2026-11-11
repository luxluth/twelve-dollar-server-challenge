# Action Chain: Ultra-High-Throughput Micro-Batched HTTP/1.1 Feed Engine

An ultra-high-throughput, sub-50ms p99 latency HTTP/1.1 feed engine implemented in **Zig 0.17** running directly on Linux `io_uring` with direct SQLite B-Tree traversal and group commits.

Designed specifically for the **$12 Server Challenge** running on a constrained environment (1 vCPU, 2 GB RAM).

---

## Technical Overview

| Attribute | Specification |
|---|---|
| **Language** | Zig 0.17 (`ReleaseFast`) |
| **OS Interface** | Linux `io_uring` via `std.os.linux.IoUring` (multishot accept & recv, provided buffer rings) |
| **Database** | SQLite 3.54.1 amalgamation with zero-SQL B-Tree cursor traversal & pre-compiled write statements |
| **Deployment Mode** | Direct (`HOST:PORT`, e.g. `0.0.0.0:80` or `127.0.0.1:3000`) |
| **Allocations** | Zero heap allocations on the hot path |
| **Batching** | 32-slot micro-batched vectorized assembly line |

---

## Architecture: Micro-Batched Staged Queue Push

Rather than executing a traditional run-to-completion model per socket, Action Chain processes requests as a continuous vectorized assembly line. Requests flow in fixed micro-batches (32 slots) to keep the hardware L1 instruction cache (L1i) 100% warm across stage iterations:

```
[ io_uring Ingress ]
        │
        ▼
[ STAGE 1: GOBBLER ] ─── Ingest raw TCP stream slices (IORING_RECV_MULTISHOT + PBUF_RING)
        │
        ▼
[ STAGE 2: SHAPER & ROUTER ] ─── SIMD HTTP tokenization & fast JWT HS256 auth extraction
        │
        ▼
[ STAGE 3: HANDLER ] ─── Direct SQLite B-Tree walk (Reads) / Prepared VDBE step (Writes)
        │
        ▼
[ STAGE 4: RESPONDER ] ─── Hardcoded JSON formatting & batched io_uring write submission
```

### 1. Ingress & Egress (`io_uring`)
* **Provided Buffer Rings (`IORING_REGISTER_PBUF_RING`)**: 4,096 buffers of 2,048 bytes registered directly with the kernel. Incoming TCP stream chunks land directly in pre-allocated buffers without kernel-to-user memory copies.
* **Multishot Operations**: `IORING_ACCEPT_MULTISHOT` accepts incoming connections repeatedly with a single submission; `IORING_RECV_MULTISHOT` reads incoming bytes continuously.
* **Syscall Amortization**: Sends and multishot operations are queued in batch and dispatched via single `io_uring_submit()` calls.
* **Streaming Reassembly**: Non-blocking connection reassembly buffer handles TCP packet fragmentation seamlessly while zero-copy requests bypass assembly buffers directly.

### 2. Zero-SQL Read Path (`GET /feed`, `GET /posts/:id`)
* Bypasses the SQL parser, tokenizer, query optimizer, and VDBE bytecode interpreter entirely for read endpoints.
* **Feed**: Directly walks SQLite's B-Tree cursor on `posts_created_at_id_idx` (`DESC, DESC`), retrieving the 20 newest post IDs in sub-microsecond time. Performs a range scan on `likes_post_id_idx` to compute like counts, seeks the `posts` table by rowid, and resolves author usernames via B-tree cursor seeks on `users`.
* **Single Post**: Direct B-Tree seek on `posts` by rowid with index seek on `likes_post_id_idx`.
* **Zero-Copy Serialization**: High-speed vector JSON string serialization (`needs_escape16` scanning 16 bytes per cycle) streaming stored timestamps directly out of the B-Tree record payload without date/time parsing overhead.

### 3. Write Path & Durability (`POST /posts`, `POST /posts/:id/like`)
* All write statements (`INSERT INTO posts ... RETURNING id, created_at`, `INSERT INTO likes ...`) are pre-compiled at startup.
* Write requests execute within group-committed transactions per micro-batch.
* Background WAL checkpointing runs on a dedicated thread at `nice 19`, preventing filesystem sync stalls on the main event loop.

### 4. Memory & Cache Alignment
* **Struct-of-Arrays (SoA)**: Batch state arrays are laid out in SoA pattern aligned to 64 bytes (`align(64)`) to eliminate false sharing and optimize CPU cache line prefetching.
* **Zero Allocations**: All buffers (ingress, pipeline slots, egress, database records) are pre-allocated at startup. No dynamic allocations (`malloc`/`free`) occur after boot.

---

## Verification & Testing

Action Chain passes 100% of the 42 checks in `test/test.sh`:

```bash
bash test/run.sh submissions/zig-action-chain-luxluth
# passed=42 failed=0
```
