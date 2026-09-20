# canvas-video

在 Emacs buffer 中播放视频：既可以打开独立播放器，也可以把视频嵌入文字和图片之间。canvas-video 使用 **libmpv** 解码与输出音频，通过 **Emacs Canvas** 显示画面，无需打开外部播放器窗口。

支持本地视频、直接媒体 URL、同一 buffer 中的多个视频，以及暂停、跳转、音量、倍速、字幕显示和拖动缩放。另提供可选的 telega 集成。

## 运行要求

- **图形界面 Emacs**，支持动态模块、Canvas 图像类型和 `canvas-refresh`。包声明的 Emacs 版本要求为 `32.0.50`；是否可用还取决于构建是否包含这些 API。
- 与运行中的 Emacs 匹配、包含 `canvas_data` API 的 **`emacs-module.h`**。
- **libmpv** 及其开发头文件、C11 编译器、pthread、Make 和 pkg-config。
- **FFmpeg 命令行工具**仅用于生成测试视频，正常播放不需要。

终端 Emacs 无法显示视频。构建脚本提供 macOS 和 Linux 分支，Linux 尚未验证。

可以在图形 Emacs 中执行以下表达式检查运行时能力；各项应为非 `nil`：

```elisp
(list :graphical (display-graphic-p)
      :modules (and (fboundp 'module-load) module-file-suffix)
      :canvas (image-type-available-p 'canvas)
      :canvas-refresh (fboundp 'canvas-refresh))
```

## 安装与开始播放

推荐使用 Emacs 内置的 `use-package :vc` 从 Git 仓库安装。请先准备好上述依赖，并确保 Git 可用。

使用 Homebrew 时，可以通过以下命令安装媒体依赖；Emacs 及其匹配的头文件需另外准备：

```sh
brew install mpv pkgconf
# 如需运行测试：
brew install ffmpeg
```

在 Emacs 配置中加入以下声明，将示例 URL 替换为项目的实际仓库地址：

```elisp
(use-package canvas-video
  :ensure t
  :vc (:url "https://github.com/guidao/canvas-video"
       :rev :newest)
  :commands (canvas-video-build
             canvas-video-open
             canvas-video-open-url
             canvas-video-insert
             canvas-video-insert-url))
```

求值该声明后，Emacs 会安装源码并注册命令，无需手动设置 `load-path`。`:rev :newest` 表示安装时选取最新提交，详见 [use-package 安装说明](https://www.gnu.org/software/emacs/manual/html_node/use-package/Install-package.html)。

首次使用时：

1. 运行 **`M-x canvas-video-build`**，编译动态模块。
2. 等待 `*canvas-video-build*` buffer 显示编译成功。
3. 运行 **`M-x canvas-video-open`**，选择视频开始播放。

编译异步执行，不阻塞编辑。首次编译成功后即可直接使用，播放命令会自动加载模块，无需重启 Emacs。使用 `C-u M-x canvas-video-build` 可强制重新编译；如果当前 Emacs 已加载旧模块，则需要重启后才能使用新版。

源码由 `package-vc` 安装到 `package-user-dir` 下的包目录，动态模块直接生成在同一目录，与 `canvas-video.el` 放在一起。编译命令会自动定位安装目录，无需另行复制产物。

命令使用当前 Emacs 的模块后缀，Makefile 会在常见 include 目录查找 `emacs-module.h`。如需指定与当前 Emacs 匹配的头文件，可运行 `M-x customize-variable RET canvas-video-emacs-include RET`，选择包含该头文件的目录后再次编译。编译命令不安装系统依赖。

也可在源码目录从终端运行 `make`，通过 `EMACS`、`EMACS_INCLUDE` 和 `PKG_CONFIG` 指定构建工具及头文件位置。构建产物为 `canvas-video-module.dylib`（macOS）或 `canvas-video-module.so`（Linux），与 Elisp 文件放在同一目录。

编译完成后使用：

| 命令 | 用途 |
| --- | --- |
| `M-x canvas-video-open` | 选择本地视频，在 `*canvas-video*` 中播放 |
| `M-x canvas-video-open-url` | 输入直接媒体 URL 或 libmpv 支持的流地址 |
| `M-x canvas-video-insert` | 在当前可编辑 buffer 的光标位置插入本地视频 |
| `M-x canvas-video-insert-url` | 在光标位置插入媒体 URL |

URL 播放优先使用直接媒体地址。网页视频提取未经验证，不保证支持需要额外提取器的网站页面。文件命令只接受本地文件，不支持 TRAMP 路径。

如需手动安装，也可以把完整源码放到 Emacs 配置目录下的 `site-lisp/canvas-video/`，用以下配置替代上面的 `use-package` 声明，然后执行相同的编译步骤：

```elisp
(add-to-list 'load-path
             (expand-file-name "site-lisp/canvas-video" user-emacs-directory))
(require 'canvas-video)
```

## 操作播放器

独立播放器和内嵌视频共用鼠标控制栏：点击进度条跳转，点击按钮暂停、快进或快退，使用音量滑块和倍速菜单调整播放。倍速菜单提供 `1x`、`1.25x`、`1.5x`、`2x`；重播、停止、字幕和移除等操作位于 **⋯** 菜单中。窄画面会精简按钮，音量滑块也可以从更多菜单打开。

拖动控制栏右下角的 **◢** 手柄可等比例缩放显示画面。每个视频独立控制，鼠标操作始终作用于所点击的视频。

| 独立播放器按键 | 操作 |
| --- | --- |
| `SPC` | 暂停 / 继续；结束或停止后重新播放 |
| `←` / `→` | 后退 / 前进 5 秒 |
| `C-←` / `C-→` | 后退 / 前进 30 秒 |
| `j` | 跳转到指定秒数 |
| `+` / `-` | 音量增加 / 减少 5 |
| `m` | 切换静音 |
| `v` | 输入播放速度，范围为 0.1–4 |
| `S` | 显示 / 隐藏已选中的字幕 |
| `g` | 从头重播 |
| `o` | 打开另一个本地视频 |
| `s` | 停止并释放播放器，保留最后画面 |
| `q` | 关闭播放器 buffer |

在内嵌视频上操作时，先把光标移到视频标记内，再使用 `C-c C-v` 前缀。例如 `C-c C-v SPC` 暂停，`C-c C-v →` 前进，`C-c C-v q` 删除当前视频。上表除 `o` 外的按键均可加此前缀使用；其中 `q` 仅移除对应视频。

## 在文档中混排视频

`canvas-video-insert` 会自动启用 `canvas-video-inline-mode`，保留当前 major mode 和普通编辑按键。多个视频各自维护播放位置、音量和暂停状态；它们默认都会输出音频，可分别静音或暂停。

以下示例选择一个本地文件，并创建包含说明文字和视频的 buffer：

```elisp
(let ((file (read-file-name "选择视频：" nil nil t)))
  (switch-to-buffer (generate-new-buffer "*video-notes*"))
  (text-mode)
  (insert "操作演示\n\n这里可以写说明文字。\n")
  (canvas-video-insert file 480 270)
  (insert "\n视频后面的文字也可以正常编辑。\n"))
```

视频使用 overlay 显示在 `[video: 路径或URL]` 文本标记上，刷新画面不会修改正文或产生撤销记录。

**内嵌视频只在当前会话中有效。** 保存文件仅保存文本标记，不会保存播放器状态；重新打开文件、复制粘贴或撤销删除，也不会自动创建播放器。标记包含所打开的文件路径或 URL，分享文档前请检查其中是否有私人路径或带凭据的地址。

删除或修改视频标记会释放对应播放器。关闭 buffer、切换 major mode 或禁用 `canvas-video-inline-mode` 也会清理资源；禁用 minor mode 时保留文本标记。停止播放会保留画面，之后点击播放可重新打开视频。

## 接入 telega

完成基本安装后，在配置中加入：

```elisp
(require 'canvas-video-telega)
(canvas-video-telega-mode 1)
```

之后按 telega 原来的方式打开普通视频消息或视频链接预览，即可在独立 Canvas 播放器中观看。视频由 telega 完整下载后播放。走外部画面播放路径的 MP4/GIF 动画也会交给 Canvas，并保留无限循环和静音参数。

适配层使用 `telega-msg-open-video`、`telega-msg--play-video` 和 `telega-ffplay-run`，因此兼容性取决于这些 telega 接口。它保留 telega 的文件打开 hook 和消息回溯处理，无需修改 `telega-video-player-command`。

当前不支持边下载边播、聊天消息内嵌视频或视频时间戳定位。聊天内动画预览、音频、依赖 ffplay 进程回调的语音播放，以及按文档发送的附件沿用 telega 原有行为。

关闭集成：

```elisp
(canvas-video-telega-mode -1)
```

## 配置与性能

```elisp
(setq canvas-video-width 960
      canvas-video-height 540
      canvas-video-inline-width 480
      canvas-video-inline-height 270
      canvas-video-refresh-rate 30
      canvas-video-audio-output nil)
```

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `canvas-video-width` / `canvas-video-height` | `960` / `540` | 独立播放器渲染尺寸 |
| `canvas-video-inline-width` / `canvas-video-inline-height` | `480` / `270` | 内嵌视频默认渲染尺寸 |
| `canvas-video-refresh-rate` | `30` | 每个视频向 Canvas 提交画面的帧率上限，范围 1–120 |
| `canvas-video-audio-output` | `nil` | libmpv 自动选择音频输出；设为 `"null"` 可静音测试 |

宽高范围为 1–4096。尺寸和音频输出设置用于新建的播放器；刷新率修改在 buffer 下一次启动播放 timer 时生效。独立播放器按 `g` 重播会采用新的默认尺寸，内嵌视频重播保留各自尺寸。

画面保持宽高比，比例不匹配时添加黑边。拖动缩放只改变显示尺寸，不提高解码与渲染分辨率；需要更多细节时，应调整渲染尺寸后重新打开。当前不会自动随 Emacs window 改变分辨率。

渲染使用 CPU，默认禁用硬件解码，没有 GPU 直接显示链路。放大画面或同时播放多个视频会增加开销，不保证 1080p/4K 实时帧率。

音画时钟由 libmpv 管理。Emacs 执行耗时 Lisp 时，画面可能停顿，恢复后提交最新帧。不可见的视频暂停向 Canvas 复制画面，但后台渲染和音频仍会继续；需要停止播放时请暂停视频或释放播放器。

## 开发与验证

在源码目录运行：

```sh
make fixture       # 生成四秒红蓝画面及提示音，不下载外部媒体
make check         # C 测试、Elisp 字节编译、ERT 测试及 telega 路由测试
make check-telega  # 单独检查 telega 适配，不连接 Telegram
make check-gui     # 启动独立图形 Emacs，完成集成测试后自动退出
```

`make fixture` 生成 `tests/fixture.mkv`，可用 `M-x canvas-video-open` 选择播放。

测试覆盖像素输出与缩放、播放控制、输入校验、播放器生命周期、多视频独立控制、编辑与删除、音量控件和 telega 路由。GUI 测试结果写入 `tests/gui-result.log`。自动测试使用 `ao=null`，不验证真实扬声器输出或网络流；GUI 测试需要可访问的图形会话。

提交问题时请描述复现步骤、预期与实际行为，并附上必要的错误信息。分享日志、配置或截图前，请移除账号、凭据、私人媒体地址和个人目录路径。

## 常见问题

- **提示缺少 Canvas API**：检查运行时能力检测结果，并确认 Emacs 与 `emacs-module.h` 来自兼容的构建。仅满足版本号不足以确认支持。
- **编译时找不到 `emacs-module.h` 或 `canvas_data`**：设置 `canvas-video-emacs-include`，或在终端通过 `EMACS_INCLUDE` 指定包含所需 API 的头文件目录。
- **找不到 libmpv**：确认安装了开发头文件，并检查 `pkg-config --cflags --libs mpv` 是否成功；非默认安装位置可能需要设置 `PKG_CONFIG_PATH`。
- **提示先构建模块或加载失败**：运行 `M-x canvas-video-build`，确认产物与 Elisp 文件同目录，并使用与运行 Emacs 兼容的架构和头文件。更新已加载的模块后重启 Emacs。
- **画面过大或播放卡顿**：减小渲染尺寸、显示缩放或同时播放的视频数量，避免阻塞 Emacs 主线程。
- **没有声音**：确认播放器未静音、音量正常，且 `canvas-video-audio-output` 没有设为 `"null"`；修改音频输出后重新打开视频。

## 源码结构

| 文件 | 职责 |
| --- | --- |
| [canvas-video.el](canvas-video.el) | 播放命令、独立及内嵌模式、Canvas 控件、timer 和生命周期管理 |
| [canvas-video-volume.el](canvas-video-volume.el) | 浮动音量滑块及鼠标交互 |
| [canvas-video-telega.el](canvas-video-telega.el) | 可选的 telega 视频路由 |
| [src/module.c](src/module.c) | Emacs 动态模块接口、参数校验和句柄回收 |
| [src/player.c](src/player.c) | libmpv 实例、渲染线程、双缓冲和播放状态 |
| [src/scale.c](src/scale.c) | 显示画面的像素缩放 |
| [tests/](tests/) | C、ERT 和图形界面集成测试 |

libmpv 回调唤醒渲染线程，将画面写入独立像素缓冲区；Emacs 主线程获取 Canvas 数据、复制最新帧并调用 `canvas-refresh`。后台线程不调用 Emacs API，原生模块也不长期持有 Canvas 指针。

每个视频持有独立播放器与状态，每个 buffer 共用一个刷新 timer。播放命令以参数数组传给 libmpv，不经过 shell；默认不加载用户的 mpv 配置和外部自动脚本。

## 许可证

Copyright (C) 2026 guidao

本项目采用 **GNU General Public License 第 3 版或任何后续版本**（`GPL-3.0-or-later`）。你可以按照该许可证使用、修改和再分发本项目；本项目不提供任何担保。完整条款见 [LICENSE](LICENSE)。

Emacs、libmpv、telega 等第三方依赖保留各自的版权和许可证，本项目的许可声明不改变其许可条款。
