#!/bin/sh
# 在手机上编 libqrtr（meson）+ pd-mapper（make）
set -e
B=/root/build

echo "=== 1) libqrtr（qrtr 仓库是 meson 构建）"
cd "$B/qrtr"
rm -rf build
meson setup build --prefix=/usr/local --buildtype=release >/tmp/qrtr-meson.log 2>&1 || {
	tail -20 /tmp/qrtr-meson.log; exit 1
}
ninja -C build >/tmp/qrtr-ninja.log 2>&1 || { tail -20 /tmp/qrtr-ninja.log; exit 1; }
ninja -C build install >/dev/null
ldconfig
ls -l /usr/local/lib/libqrtr.so* /usr/local/include/libqrtr.h 2>/dev/null | head -4

echo
echo "=== 2) pd-mapper"
cd "$B/pd-mapper"
make clean >/dev/null 2>&1 || true
make CFLAGS="-Wall -g -O2 -I/usr/local/include" \
	LDFLAGS="-lqrtr -llzma -L/usr/local/lib -Wl,-rpath,/usr/local/lib" 2>&1 | tail -5
ls -l pd-mapper

echo
echo "=== 3) 安装 + 单元"
make install prefix=/usr/local >/dev/null
ls -l /usr/local/bin/pd-mapper /usr/local/lib/systemd/system/pd-mapper.service
echo "--- 单元内容:"
cat /usr/local/lib/systemd/system/pd-mapper.service
