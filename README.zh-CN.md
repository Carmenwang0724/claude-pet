# ClaudePet

一只住在 macOS 桌面上的宠物，帮你盯着 Claude Code 的会话。

她在屏幕上闲逛，跳上窗口，爬屏幕边缘，跟鼠标玩，偶尔还会抱走几个桌面图标。头顶有一张小清单，哪个 Claude 会话还在跑、哪个在等你、哪个做完了，一眼能看出来。

程序是一个很小的 Swift/AppKit app，支持 Petdex（Codex pet）格式的任意角色。仓库里不带任何美术素材。

English: [README.md](README.md)

## 她会做什么

- 大部分时间站着。偶尔走一小段、原地跳一下，或者摆一个素材里的备用姿势。
- 窗口顶上有空位时会跳上去。你拖动那个窗口，她跟着走。
- 走到屏幕左右两边会往上爬。爬到顶可能翻到菜单栏下面倒着走一段，再松手掉下来。
- 鼠标在她附近停下，她走过去挥手。鼠标猛冲过去，她吓得跳开。鼠标在她头上来回蹭，她会开心地跳一下。
- 电脑 5 分钟没人碰，她就睡觉。你回来她就醒。
- 连续用电脑 50 分钟，她提醒你休息。凌晨 0 点到 5 点还在用，她催你睡觉。
- 每次启动的出场方式不一样。

## 任务清单

每个有动静的 Claude 会话在她头顶占一行。

| 圆点 | 状态 | 含义 | 什么时候消失 |
| --- | --- | --- | --- |
| 橙色 | Needs approval、Needs input | Claude 卡在权限弹窗或提问上 | 你处理之后 |
| 红色 | Blocked | 这一轮报错中断 | 你点这一行，或在那个会话里发新消息 |
| 绿色 | Ready | 这一轮做完，你还没看 | 同上 |
| 蓝色 | Running | 还在跑 | 做完、出错，或被你中断 |

- 按紧急程度排序：等你处理的在最上面，然后是出错、做完、在跑。
- 每行有会话标题和已经持续的时间。标题就是 Claude 桌面版里显示的那个。
- 点一行，会切到 Claude 并打开那个会话。这一步用的是 Claude 桌面版的 `claude://` 链接，所以只有在桌面版里开的会话才能精确打开。
- 最多显示 5 行，多出来的合并成一行「+N more」。
- 你中断一轮时 Claude 不发事件。她靠读会话记录文件的末尾来发现，需要 5 到 10 秒。
- 清单默认跟着她走，可以在菜单里改成固定在右上角。

她对 Claude 状态的反应：

| Claude | 她 |
| --- | --- |
| 开始干活 | 翻开书看几秒 |
| 等你批准权限、等你回答 | 从墙上下来或醒过来，站住，每 6 秒挥一次手 |
| 一轮做完 | 跳一下，摆 review 姿势 40 秒 |
| 一轮报错 | 摔一跤 |

## 去桌面捣乱

她会跑到桌面上，把图标一个个拎起来顶在头上，跑到别处放下。过几分钟再回来，跑到每个被挪过的图标那里，把它放回去。

- 菜单里的 **Mess Up the Desktop** 一次搬 6 个。打开 **Visit the Desktop on Her Own** 后，她每隔 15 到 30 分钟自己去一趟，搬 4 个，而且只在你在电脑前的时候去。
- **Tidy the Desktop** 让她去把图标搬回来。每次捣乱后 4 到 8 分钟她也会自己去。到时候如果你不在，或者她睡着了，就改成一次性全部放回。
- 她抱着图标跑的时候，Finder 里的真图标跟着她动，每秒大约更新 16 次。桌面被窗口挡住的地方，她会显示一个带文件名的图标副本，所以你仍然看得见她抱的是哪个文件。
- Claude 需要你、你用鼠标把她拎起来，或者一趟超过 150 秒，这趟就提前结束。整理被打断时，图标照样全部放回。

对文件的影响只有一项：图标在桌面上的位置。不移动、不改名、不打开、不删除任何文件。

几件要知道的事：

- macOS 会问一次是否允许 ClaudePet 控制 Finder。想收回，到「系统设置 > 隐私与安全性 > 自动化」里关掉。
- 动第一个图标之前，原来的布局会先存到 `~/.claude-pet/desktop-snapshot.json`。存不成功她就不动桌面。
- Finder 只对手动摆过或脚本摆过的图标报告坐标。由 Finder 自己排列的图标，它什么都不报，所以她没法知道这些图标画在哪里。这种情况下她跑到图标堆里的某个位置，图标直接跳到她手上。有自己坐标的图标，她会跑到图标所在的位置去拿。整理时，原本由 Finder 排列的图标会交还给 Finder 自己排。
- 开着自动排序的桌面，图标位置是锁住的，所以她要先把排序关掉。Finder 的脚本接口认识的排序方式有名称、种类、大小、标签、修改日期、创建日期，这几种她能自动开回去。其他方式，比如添加日期，只能你自己在桌面右键菜单里重选。遇到这种情况，从菜单发起时她会先问你，她自己去桌面时则直接放弃这一趟。

## 鼠标和菜单

- 单击她：打开最需要你处理的会话，没有的话只把 Claude 切到前面。她自己也会跳到 Claude 窗口顶上。
- 拖动她：拎到别处。松手时带速度会被扔出去。
- 把文件拖到她身上：文件路径被复制到剪贴板，同时切到 Claude，你直接粘贴。文件本身不动。
- 右键：菜单。

| 菜单项 | 作用 |
| --- | --- |
| Open Claude | 把 Claude 桌面版切到前面 |
| Pet | 在 `~/.petdex/pets` 和 `~/.codex/pets` 里装的角色之间切换 |
| Size | Small、Medium、Large、Extra Large |
| Stay Put | 不闲逛，也不自己去桌面 |
| Climb Walls and Ceiling | 关掉后只在地面和窗口顶上活动 |
| React to the Mouse | 关掉后不再走向鼠标、躲鼠标，摸头也没反应 |
| Break and Bedtime Reminders | 关掉后不再提醒休息和催睡 |
| Pin Task List to Top Right | 清单固定在右上角，不跟着她走 |
| Swap Left and Right Walk | 有些素材把左右两行跑步画反了，用这项纠正 |
| Mess Up the Desktop、Tidy the Desktop、Visit the Desktop on Her Own | 见「去桌面捣乱」 |
| Clear Task List | 清空清单 |
| Quit | 退出 |

## 安装

需要 macOS 13 或更高版本、Xcode Command Line Tools（`xcode-select --install`）、Python 3 和 `jq`（macOS 15 起系统自带）。任务清单需要 Claude Code。

1. 准备一个角色。到 [petdex.dev](https://petdex.dev) 挑一只，把它的 `pet.json` 和 `spritesheet.webp` 放进 `~/.petdex/pets/<名字>/`。装了 Node 的话，`npx petdex install <名字>` 会把它装到 `~/.codex/pets`，效果一样。

2. 编译。

   ```bash
   ./build.sh
   ```

3. 安装 Claude Code 的 hooks。脚本会先备份 `~/.claude/settings.json`，重复运行也没问题。

   ```bash
   python3 install_hooks.py
   ```

4. 启动。

   ```bash
   open ClaudePet.app
   ```

她不会开机自启。退出用右键菜单里的 Quit。

卸载 hooks：

```bash
python3 install_hooks.py --uninstall
```

之后删掉这个文件夹和 `~/.claude-pet`，这个项目创建的东西就都没了。

## 它动了哪些地方

- `~/.claude/settings.json`：12 条 hooks，每条只是在后台调用 `~/.claude-pet/hook.sh`。每次安装都会在旁边留一份带日期的备份。
- `~/.claude-pet/`：hook 脚本、事件记录、进程号文件、切好的动作帧、保存的桌面布局。一条事件只含会话编号、事件名、工具名、会话标题、工作目录和会话记录文件的路径，不含提示词，也不含工具输入。宠物没在运行时什么都不写。
- 只读的两处：Claude 桌面版的会话文件，用来取标题。正在跑的会话的记录文件末尾 32 KB，用来发现被中断的那一轮。读到的内容不保存。
- 剪贴板：只有你把文件拖到她身上时才写入。
- Finder：只改桌面图标的位置和桌面的排序方式，细节见上文。

## 占用

在一台 Apple 芯片的笔记本上实测。

| 状态 | CPU | 内存 |
| --- | --- | --- |
| 睡着 | 0.6% 以下 | 13 MB |
| 站着 | 1% 到 2% | 13 MB |
| 走路或爬墙，带着任务清单 | 4% 到 6% | 14 到 15 MB |

占用低靠这几件事：

- 动作帧由一个一次性的辅助进程切好，以压缩文件的形式存在缓存里。主程序只映射这些文件，同一时间最多解开两个动作。
- 主循环每秒跑 4 到 30 次，随她在做什么而变。
- 任务清单、气泡和抱着的图标都是宠物窗口的子窗口，跟着它一起移动，不需要单独移动。

## 代码结构

| 路径 | 作用 |
| --- | --- |
| `Sources/App/` | 启动、命令行模式、所有路径和可调的数字（`PetConfig.swift`） |
| `Sources/Pet/PetController.swift` | 主循环、公共状态、画面和窗口摆放 |
| `Sources/Pet/PetMovement.swift` | 出场、走路、掉落、跳跃、爬墙、倒挂 |
| `Sources/Pet/PetBehavior.swift` | 选下一个动作、鼠标互动、睡觉、提醒 |
| `Sources/Pet/PetErrand.swift` | 去桌面的整套流程 |
| `Sources/Pet/PetClaude.swift` | 对 Claude 状态的反应、清单的行、打开会话 |
| `Sources/Pet/PetMenu.swift` | 鼠标手势、拖入文件、菜单、调试命令 |
| `Sources/Pet/PetOverlay.swift` | 清单和气泡放在哪里 |
| `Sources/Atlas/` | 把素材大图切成一帧一帧，再从缓存里读回来 |
| `Sources/Sessions/` | 读 hook 事件、跟踪每个会话、取会话标题 |
| `Sources/Windows/` | 透明窗口、清单的画法、窗口扫描 |
| `Sources/Desktop/DesktopMischief.swift` | 通过 Finder 读桌面，保存和恢复布局 |
| `Sources/Desktop/DesktopIconMover.swift` | 用一条 Apple event 直接移动单个图标 |
| `hooks/hook.sh` | Claude Code 每个事件调用一次，往事件记录里追加一行 |
| `install_hooks.py` | 安装或卸载 hooks |
| `build.sh` | 编译 `Sources` 下的全部文件，组装出 `ClaudePet.app` |

改完代码运行 `./build.sh`，退出正在跑的宠物，再打开新的。改了切图逻辑要把 `PetConfig.atlasCacheVersion` 加 1，缓存才会重建。

## 调试

检查一份素材切得对不对。这条命令打印每个动作的帧数，并存一张总览图：

```bash
ClaudePet.app/Contents/MacOS/ClaudePet --dump-atlas ~/.petdex/pets/<名字> sheet.png
```

让正在运行的宠物把当前状态写到 `~/.claude-pet/debug.json`：

```bash
touch ~/.claude-pet/debug-request
```

往 `debug-request` 里写一条命令可以直接指挥她：

| 命令 | 效果 |
| --- | --- |
| `jump` | 跳到另一个能站的地方 |
| `drop 760 800` | 从指定位置掉落 |
| `walk left`、`walk right` | 朝一边走 |
| `climb left`、`climb right` | 开始爬那一侧 |
| `enter` | 重新出场 |
| `sleep`、`awake 600` | 睡觉；醒来并在 600 秒内不睡 |
| `remind`、`night` | 弹出休息提醒、催睡提醒 |
| `click` | 等同于单击她 |
| `board-click 0`、`board-click 0 dry` | 点清单第一行；加 `dry` 只记录链接，不真的打开 |
| `mouse rush`、`mouse pet`、`mouse rest` | 回放一段预设的鼠标轨迹 |
| `snapshot /tmp/pet.png`、`snapshot-board /tmp/board.png`、`snapshot-icon /tmp/icon.png` | 把宠物、任务清单、抱着的图标存成图片 |
| `desktop-rehearse` | 用假图标彩排一趟，完全不碰 Finder |
| `desktop-probe` | 只读桌面，不改动 |
| `desktop-mess 4`、`desktop-tidy` | 搬 4 个图标；开始整理 |
| `desktop-restore` | 一次性把图标全部放回 |

## 美术素材

角色来自 [petdex.dev](https://petdex.dev) 的社区作品。每个角色归它的作者所有，其中很多是同人作品，使用时请遵守作者的条款。本仓库不附带任何角色素材。
