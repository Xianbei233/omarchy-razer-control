# 权限和安装说明

构建：`cargo build --release --locked`。本机 `plugins.md`、bar README、现有 `shell.json` 和插件 `manifest.json` 表明：插件文件在 `~/.config/omarchy/plugins/<id>/`；manifest 声明 `id`、`kinds: ["bar-widget"]` 和 `entryPoints.barWidget`；`shell.json` 以对象条目管理 `plugins[]`，bar item 在 `bar.layout.{left,center,right}[]` 中使用 `{ "id": "..." }`。脚本只合并插件 ID 与 `bar.layout.right`，备份现存 shell 配置及目标插件目录，不创建独立 layout 文件。要求 jq 与本仓库 `plugin/` 内容已就绪。不得将脚本改成写系统插件目录。

udev 规则为可选文件，仅匹配 vendor/product 1532:0270 并使用 `uaccess`。安装规则属于管理员权限操作，本项目不自动执行。管理员应先查看规则内容，再手工复制至发行版对应规则目录、reload udev 并重新插拔设备。

脚本与配置变更可在临时 HOME/XDG_CONFIG_HOME 下沙箱验证；不要用真实 HID 写入作为安装验证。
