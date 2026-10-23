"""Сквозная проверка прокси для Telegram (zapret.sh telegram test): то же рукопожатие, что делает
Telegram Desktop (obfuscated2 с dd-секретом, padded intermediate), и первый запрос авторизации
req_pq_multi без шифрования. Работает, если ответ resPQ пришёл от сервера Telegram.
Запуск: check.py <host> <port> <secret: 32 hex> [номер DC, по умолчанию 2]"""
import hashlib, os, socket, struct, sys, time
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

host, port, secret = sys.argv[1], int(sys.argv[2]), bytes.fromhex(sys.argv[3])
dc = int(sys.argv[4]) if len(sys.argv) > 4 else 2

while True:
    init = bytearray(os.urandom(64))
    if init[0] == 0xef or init[:4] in (b"HEAD", b"POST", b"GET ", b"OPTI", b"\xee\xee\xee\xee", b"\xdd\xdd\xdd\xdd", b"\x16\x03\x01\x02") or init[4:8] == b"\0\0\0\0":
        continue
    break
init[56:60] = b"\xdd\xdd\xdd\xdd"            # padded intermediate
init[60:62] = struct.pack("<h", dc)
rev = bytes(init[8:56])[::-1]
enc_key = hashlib.sha256(bytes(init[8:40]) + secret).digest(); enc_iv = bytes(init[40:56])
dec_key = hashlib.sha256(rev[:32] + secret).digest(); dec_iv = rev[32:48]
enc = Cipher(algorithms.AES(enc_key), modes.CTR(enc_iv)).encryptor()
dec = Cipher(algorithms.AES(dec_key), modes.CTR(dec_iv)).decryptor()
encrypted = enc.update(bytes(init))
init[56:64] = encrypted[56:64]

nonce = os.urandom(16)
body = struct.pack("<I", 0xbe7e8ef1) + nonce                       # req_pq_multi
msg = struct.pack("<qqi", 0, int(time.time()) << 32, len(body)) + body
payload = struct.pack("<I", len(msg)) + msg

t0 = time.time()
s = socket.create_connection((host, port), timeout=15)
s.sendall(bytes(init) + enc.update(payload))
buf = b""
try:
    while len(buf) < 4 or len(buf) < 4 + struct.unpack("<I", buf[:4])[0]:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += dec.update(chunk)
except socket.timeout:
    pass
dt = time.time() - t0
if len(buf) >= 4 + 20 + 4 + 16:
    ln = struct.unpack("<I", buf[:4])[0] & 0x7fffffff
    m = buf[4:4 + ln]
    ctor = struct.unpack("<I", m[20:24])[0]
    ok = ctor == 0x05162463 and m[24:40] == nonce
    print("OK resPQ from DC%d in %.2fs" % (dc, dt) if ok else "unexpected reply ctor=%08x len=%d" % (ctor, ln))
    sys.exit(0 if ok else 1)
print("FAIL: no reply in %.1fs (got %d bytes)" % (dt, len(buf)))
sys.exit(1)
