#!/bin/sh
# Debian 的 wlroots 0.20.2 带了「layer-shell 0 尺寸不报错」的 revert（phosh 需要它），
# Arch 没带 -> phosh 一启动就被 phoc 以协议错误打掉。
# 这里把 Debian 的 arm64 .so 取下来，先放临时目录用 LD_LIBRARY_PATH 验证。
set -e
WORK=/tmp/wlrdeb
mkdir -p "$WORK"
cd "$WORK"

URL=https://deb.debian.org/debian/pool/main/w/wlroots/libwlroots-0.20_0.20.2-1_arm64.deb
if [ ! -f libwlroots.deb ]; then
	echo "== 下载 $URL"
	curl -fL -o libwlroots.deb "$URL" || { echo "!! 下载失败"; exit 1; }
fi
ls -l libwlroots.deb

python3 - <<'PY'
import lzma, os, tarfile, io

# 极简 ar 解析（.deb 是 ar 归档）
f = open("/tmp/wlrdeb/libwlroots.deb", "rb")
assert f.read(8) == b"!<arch>\n"
members = {}
while True:
    hdr = f.read(60)
    if len(hdr) < 60:
        break
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    data = f.read(size)
    if size % 2:
        f.read(1)
    members[name] = data
print("members:", list(members))

for name, data in members.items():
    if not name.startswith("data.tar"):
        continue
    raw = data
    if name.endswith(".xz"):
        raw = lzma.decompress(raw)
    elif name.endswith(".gz"):
        import gzip
        raw = gzip.decompress(raw)
    tf = tarfile.open(fileobj=io.BytesIO(raw))
    got = 0
    for m in tf:
        if "libwlroots-0.20.so" in m.name and m.isfile():
            dest = os.path.join("/tmp/wlrdeb", os.path.basename(m.name))
            with open(dest, "wb") as out:
                out.write(tf.extractfile(m).read())
            print("extracted:", m.name, "->", dest)
            got += 1
    print("files:", got)
PY

echo "== 临时目录内容:"
ls -l "$WORK"
echo "== 依赖检查:"
ldd "$WORK"/libwlroots-0.20.so* 2>&1 | grep -E 'not found|=>' | head -12
