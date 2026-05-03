// Per-pair AES-128-CTR encryption for the broadcast UDP transport.
//
// On a TSN broadcast subnet every datagram is visible to every host, so the
// MPC protocol's per-recipient secret shares must be encrypted under a key
// known only to the (sender, recipient) pair. We derive a deterministic
// per-pair key from the protocol seed and the two party ids — both peers
// compute the same key locally, no key exchange on the wire.
//
// Cipher: AES-128-CTR via OpenSSL EVP. The platform CPUs (Xeon E5-2620 v3)
// have AES-NI, so per-pair encrypt/decrypt is roughly free against the
// ~50 MB/s wire rate (AES-NI delivers 3-5 GB/s).
//
// Nonce uniqueness: the caller must pass a 12-byte nonce that is unique
// per (key, message). Our wire format is multi-fragment so we encode
// (channel_role, target_pid, sender_id, seq, idx) into the nonce; the
// per-pair (sender_id, target_pid, seq, idx) tuple gives uniqueness
// within the pair, and channel_role separates the ios and ios2 streams.
#pragma once

#include <openssl/evp.h>
#include <cstdint>
#include <cstring>
#include <string>

namespace io::aes_ctr {

// Derive K_{i, j} = first 16 bytes of SHA-256(seed_str || "|" || lo || "|" || hi)
// where lo=min(i,j), hi=max(i,j). Both peers compute the same value.
inline void derive_pair_key(uint64_t seed, int i, int j, uint8_t out_key[16]) {
  int lo = i < j ? i : j;
  int hi = i < j ? j : i;
  char buf[64];
  int n = std::snprintf(buf, sizeof(buf), "asterisk-bcast|%llu|%d|%d",
                        (unsigned long long)seed, lo, hi);
  uint8_t digest[32];
  unsigned int dlen = sizeof(digest);
  EVP_Digest(buf, (size_t)n, digest, &dlen, EVP_sha256(), nullptr);
  std::memcpy(out_key, digest, 16);
}

// Build a 12-byte AES-CTR nonce. Caller responsibility: every (key, nonce)
// pair must be used at most once. We pack the protocol-level uniqueness
// fields into the IV so each (sender, target, channel_role, seq, idx) gets
// a distinct nonce.
//   bytes 0:    channel_role (0 = ios, 1 = ios2, etc.)
//   bytes 1:    sender_id (uint8)
//   bytes 2:    target_pid (uint8)
//   bytes 3:    reserved (zero)
//   bytes 4..7: seq (little-endian uint32)
//   bytes 8..9: idx (little-endian uint16)
//   bytes 10..11: zero
inline void build_nonce(uint8_t channel_role, uint8_t sender_id,
                        uint8_t target_pid, uint32_t seq, uint16_t idx,
                        uint8_t out_nonce[12]) {
  out_nonce[0]  = channel_role;
  out_nonce[1]  = sender_id;
  out_nonce[2]  = target_pid;
  out_nonce[3]  = 0;
  std::memcpy(out_nonce + 4, &seq, 4);
  std::memcpy(out_nonce + 8, &idx, 2);
  out_nonce[10] = 0;
  out_nonce[11] = 0;
}

// Encrypt or decrypt `len` bytes of `in` into `out` using AES-128-CTR.
// AES-CTR is symmetric; the same call works in both directions.
// `iv` must be the same 16 bytes across both peers (we 0-pad the 12-byte
// nonce to 16 bytes — the kernel/EVP layer handles the counter rollover
// internally for messages up to 2^32 blocks).
inline void crypt(const uint8_t key[16], const uint8_t nonce[12],
                  const uint8_t* in, uint8_t* out, size_t len) {
  if (len == 0) return;
  uint8_t iv[16] = {};
  std::memcpy(iv, nonce, 12);  // counter bytes 12..15 start at 0
  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  int outl = 0, finl = 0;
  EVP_EncryptInit_ex(ctx, EVP_aes_128_ctr(), nullptr, key, iv);
  EVP_EncryptUpdate(ctx, out, &outl, in, (int)len);
  EVP_EncryptFinal_ex(ctx, out + outl, &finl);
  EVP_CIPHER_CTX_free(ctx);
}

}  // namespace io::aes_ctr
