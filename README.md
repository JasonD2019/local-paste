# Local Paste

macOS 菜单栏剪贴板历史。复制文字、文件路径或图片后自动记下，用 **⌘⇧V** 打开面板，回车粘贴到当前应用；粘贴/复制后该条移到列表最左侧。

记录存在本机 `~/Library/Application Support/LocalPaste/`，不上传。密码管理器（1Password、Bitwarden、钥匙串、Passwords）里的复制会被跳过。

## 使用说明

需要：**macOS 13+**，Apple 芯片，已安装 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone git@github.com:JasonD2019/local-paste.git
cd local-paste
mkdir -p LocalPaste.app/Contents/MacOS
swiftc main.swift -O -o LocalPaste.app/Contents/MacOS/LocalPaste -framework AppKit -framework ApplicationServices -framework CryptoKit
cp Info.plist LocalPaste.app/Contents/Info.plist
codesign --force --sign - --entitlements entitlements.plist LocalPaste.app
open LocalPaste.app
```

第一次打开后：

1. 菜单栏出现剪贴板图标；若系统提示辅助功能，去 **系统设置 → 隐私与安全性 → 辅助功能**，打开 **Local Paste**
2. 复制一段文字，再按 **⌘⇧V**
3. 方向键选择，回车粘贴；⌘P 置顶，⌫ 删除

## 快捷键

| 按键 | 作用 |
| --- | --- |
| ⌘⇧V | 打开 / 关闭面板 |
| 回车 | 粘贴到刚才的应用 |
| ⌘回车 | 只复制，不粘贴 |
| ⌘P | 置顶 / 取消置顶 |
| ⌫ | 删除当前条 |
| ⎋ | 关闭 |

## 仓库里有什么

- `main.swift`：全部源码
- `Info.plist`：App 包信息（编译时拷进 `LocalPaste.app`）
- `entitlements.plist`：签名用
- `LocalPaste.app/`：本机编译产物，不提交
