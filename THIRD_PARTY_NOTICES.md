# 第三方组件声明

## 7-Zip

7zMac 内置的压缩引擎 `7zz` 由 [7-Zip](https://www.7-zip.org/) 26.04 官方源码编译而成，
版权所有 © 1999-2026 Igor Pavlov。

- 7-Zip 的大部分代码以 **GNU LGPL 2.1 或更高版本** 授权；
- 部分代码以 **BSD 3-clause** 授权；
- RAR 解压代码受 **unRAR 许可限制**：不得用于开发 RAR（WinRAR）兼容的压缩器。

完整许可文本见 7-Zip 源码包中的 `DOC/License.txt`、`DOC/copying.txt`、`DOC/unRarLicense.txt`
（运行 `scripts/fetch-7zip.sh` 后位于 `vendor/7zip/DOC/`）。

### 对 7-Zip 的修改

`vendor/patches/0001-zip-codepage-iconv.patch`：在非 Windows 平台上，让 ZIP 文件名的 `-mcp=<代码页>`
参数真正生效（通过 iconv 转码），用于正确显示 Windows 中文系统生成的 GBK 文件名 ZIP。
该补丁与 7-Zip 采用相同许可（LGPL 2.1+）。

### 源码获取

`scripts/fetch-7zip.sh` 从 7-Zip 官方 GitHub 发布页下载源码，校验 SHA-256 后打补丁；
`scripts/build-7zz.sh` 编译出 `7zz`。任何人都可以用这两个脚本从源码重新构建内置引擎。
