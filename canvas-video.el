;;; canvas-video.el --- Play and embed videos with libmpv -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guidao
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is part of canvas-video.
;;
;; canvas-video is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; canvas-video is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with canvas-video.  If not, see <https://www.gnu.org/licenses/>.

;; Version: 0.2.0
;; Package-Requires: ((emacs "32.0.50"))
;; Keywords: multimedia
;;; Commentary:
;; Build with canvas-video-build.  Use canvas-video-open for a dedicated player, or
;; canvas-video-insert for videos mixed with editable text and images.
;;; Code:
(require 'image)
(require 'cl-lib)
(require 'subr-x)
(require 'compile)

;; A reload must close handles owned by the previous implementation before
;; replacing its accessors and timer callbacks.
(when (fboundp 'canvas-video--cleanup-all) (canvas-video--cleanup-all))

(defgroup canvas-video nil
  "Play videos inside Emacs buffers using libmpv."
  :group 'multimedia)
(defcustom canvas-video-width 960 "Dedicated player render width." :type 'integer)
(defcustom canvas-video-height 540 "Dedicated player render height." :type 'integer)
(defcustom canvas-video-inline-width 480 "Inline video render width." :type 'integer)
(defcustom canvas-video-inline-height 270 "Inline video render height." :type 'integer)
(defcustom canvas-video-refresh-rate 30
  "Maximum canvas submissions per second per video.
Decoders follow their own media clocks.  Missed frames are dropped.
Changes apply when a buffer's next playback timer starts."
  :type 'number)
(defcustom canvas-video-audio-output nil
  "libmpv audio driver, or nil for automatic selection.
Use \"null\" for silent testing.  Applies to newly created instances."
  :type '(choice (const :tag "Automatic" nil) string))
(defcustom canvas-video-emacs-include nil
  "Directory containing the matching emacs-module.h, or nil for Make defaults.
The header must provide the canvas_data API used by the running Emacs."
  :type '(choice (const :tag "Automatic" nil) directory)
  :group 'canvas-video)
(defconst canvas-video--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(declare-function canvas-video--native-create "canvas-video-module" (width height audio-output))
(declare-function canvas-video--native-close "canvas-video-module" (player))
(declare-function canvas-video--native-command "canvas-video-module" (player args))
(declare-function canvas-video--native-present "canvas-video-module" (player canvas))
(declare-function canvas-video--native-status "canvas-video-module" (player))
(declare-function canvas-video--native-scale "canvas-video-module" (source destination))

(cl-defstruct (canvas-video--instance (:constructor canvas-video--make-instance))
  buffer overlay source placeholder width height audio player canvas
  status (next-status 0) last-error dedicated)
(defvar-local canvas-video--instances nil)
(defvar-local canvas-video--dedicated nil)
(defvar-local canvas-video--timer nil)
(defvar canvas-video--target nil "Dynamically bound target of a mouse action.")

(defun canvas-video--build-finished (_buffer status)
  "Report a successful module build indicated by STATUS."
  (when (string-prefix-p "finished" status)
    (message (if (featurep 'canvas-video-module)
                 "Module built. Restart Emacs to use the rebuilt module"
               "Module built. Use M-x canvas-video-open to play a video"))))

;;;###autoload
(defun canvas-video-build (&optional force)
  "Build the native module asynchronously and return its compilation buffer.
With prefix argument FORCE, rebuild even when the module is up to date.
Run Make in the package directory, using the running Emacs's module suffix.
Customize `canvas-video-emacs-include' to select a matching header directory.
Build dependencies must already be installed.  A loaded native module cannot
be replaced in this session; restart Emacs after rebuilding it."
  (interactive "P")
  (unless (and module-file-suffix (fboundp 'module-load))
    (user-error "This Emacs was built without dynamic module support"))
  (let* ((default-directory canvas-video--directory)
         (make (executable-find "make"))
         (build-shell (executable-find "sh"))
         (include (and canvas-video-emacs-include
                       (expand-file-name canvas-video-emacs-include))))
    (unless make
      (user-error "Make is not available; install it and add it to exec-path"))
    (unless build-shell
      (user-error "A POSIX sh is required to build the module"))
    (unless (file-readable-p "Makefile")
      (user-error "Package sources are missing; install the complete canvas-video source directory"))
    (when (and include (not (file-readable-p (expand-file-name "emacs-module.h" include))))
      (user-error "canvas-video-emacs-include must contain emacs-module.h"))
    ;; Make recipes and shell-quote-argument use POSIX shell syntax.  The
    ;; user's interactive shell may use different quoting conventions.
    (let* ((shell-file-name build-shell)
           (shell-command-switch "-c")
           (buffer
            (compilation-start
             (mapconcat #'shell-quote-argument
                        (append (list make "all"
                                      (concat "MODULE_SUFFIX=" module-file-suffix))
                                (when force '("-B"))
                                (when include (list (concat "EMACS_INCLUDE=" include))))
                        " ")
             'compilation-mode (lambda (_mode) "*canvas-video-build*"))))
      (with-current-buffer buffer
        (setq-local shell-file-name build-shell
                    shell-command-switch "-c")
        (add-hook 'compilation-finish-functions #'canvas-video--build-finished nil t))
      buffer)))

(defun canvas-video--load-module ()
  "Load the native module and check canvas support."
  (unless (and (fboundp 'canvas-refresh) (image-type-available-p 'canvas))
    (user-error "This Emacs needs the canvas image API (Emacs 32 development builds)"))
  (unless (and module-file-suffix (fboundp 'module-load))
    (user-error "This Emacs was built without dynamic module support"))
  (unless (featurep 'canvas-video-module)
    (let ((file (expand-file-name (concat "canvas-video-module" module-file-suffix)
                                  canvas-video--directory)))
      (unless (file-exists-p file)
        (user-error "Build the module first: M-x canvas-video-build"))
      (module-load file))))

(defun canvas-video--check-display (width height)
  "Check the graphical environment and render WIDTH and HEIGHT."
  (unless (display-graphic-p)
    (user-error "Canvas video requires a graphical Emacs frame"))
  (unless (and (integerp width) (<= 1 width 4096)
               (integerp height) (<= 1 height 4096))
    (user-error "Video width and height must be integers between 1 and 4096"))
  (unless (and (numberp canvas-video-refresh-rate) (<= 1 canvas-video-refresh-rate 120))
    (user-error "Refresh rate must be between 1 and 120"))
  (canvas-video--load-module))

(defun canvas-video--local-file (file)
  "Validate FILE and return its absolute local path."
  (when (file-remote-p file)
    (user-error "Use a local file or one of the canvas-video URL commands"))
  (setq file (expand-file-name file))
  (unless (and (file-readable-p file) (not (file-directory-p file)))
    (user-error "Not a readable video file: %s" file))
  file)

(defun canvas-video--url (url)
  "Trim and validate media URL."
  (when (string-empty-p (string-trim url)) (user-error "Enter a media URL"))
  (string-trim url))

(defun canvas-video--clock (seconds)
  "Format SECONDS as a playback clock, including unknown values."
  (if (or (null seconds) (< seconds 0)) "--:--"
    (let* ((total (floor seconds)) (hours (/ total 3600))
           (minutes (% (/ total 60) 60)) (secs (% total 60)))
      (if (> hours 0) (format "%d:%02d:%02d" hours minutes secs)
        (format "%02d:%02d" minutes secs)))))

(defun canvas-video--status-text (instance)
  "Return playback information for INSTANCE."
  (let ((s (canvas-video--instance-status instance)))
    (format "%s  %s / %s  Volume %.0f%%  %.2fx"
            (cond ((plist-get s :error) "Error")
                  ((not (canvas-video--instance-player instance)) "Stopped")
                  ((plist-get s :eof) "Finished")
                  ((plist-get s :idle) "Loading")
                  ((plist-get s :paused) "Paused") (t "Playing"))
            (canvas-video--clock (plist-get s :position))
            (canvas-video--clock (plist-get s :duration))
            (or (plist-get s :volume) 100) (or (plist-get s :speed) 1))))

(defun canvas-video--header ()
  "Return the dedicated player's header line."
  (if canvas-video--dedicated
      (concat " " (canvas-video--status-text canvas-video--dedicated)
              "  | SPC pause · ←/→ seek · q quit")
    " No video"))

(defun canvas-video--at-point ()
  "Return the video whose placeholder contains point."
  (cl-loop for overlay in (overlays-at (point))
           thereis (overlay-get overlay 'canvas-video-instance)))

(defun canvas-video--current ()
  "Resolve the mouse target, video at point, or dedicated player."
  (let ((instance (or canvas-video--target (canvas-video--at-point)
                      canvas-video--dedicated)))
    (unless (and instance (memq instance canvas-video--instances))
      (user-error "Move point onto a video or use its mouse controls"))
    instance))

(defun canvas-video--invoke (instance command)
  "Run COMMAND with INSTANCE as its explicit control target."
  (let ((buffer (canvas-video--instance-buffer instance)))
    (unless (buffer-live-p buffer) (user-error "This video was removed"))
    (with-current-buffer buffer
      (let ((canvas-video--target instance))
        (canvas-video--current)
        (call-interactively command)))))

(require 'color)
(autoload 'canvas-video-volume-popup "canvas-video-volume" nil t)

(defface canvas-video-control
  '((((background dark)) :background "#20262e" :foreground "#d7dee8")
    (t :background "#edf1f5" :foreground "#344050"))
  "Surface and icon colors for video controls." :group 'canvas-video)
(defface canvas-video-accent
  '((((background dark)) :foreground "#72d6be")
    (t :foreground "#147d68"))
  "Accent used for the play button and elapsed progress." :group 'canvas-video)
(defface canvas-video-secondary
  '((((background dark)) :foreground "#95a3b5")
    (t :foreground "#657386"))
  "Secondary text in video controls." :group 'canvas-video)

(defvar canvas-video--control-images (make-hash-table :test #'equal))

(defun canvas-video--control-colors ()
  "Resolve control colors for the current theme."
  (mapcar (lambda (pair)
            (let ((value (face-attribute (car pair) (cdr pair) nil t)))
              (if (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value) value
                (apply #'format "#%02x%02x%02x"
                       (mapcar (lambda (c) (/ c 257)) (color-values value))))))
          '((canvas-video-control . :background)
            (canvas-video-control . :foreground)
            (canvas-video-accent . :foreground)
            (canvas-video-secondary . :foreground))))

(defun canvas-video--control-image (width height body)
  "Create a cached SVG of WIDTH, HEIGHT and BODY."
  (when (image-type-available-p 'svg)
    (let* ((key (list width height body))
           (cached (gethash key canvas-video--control-images)))
      (or cached
          (let ((image (create-image
                        (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>%s</svg>"
                                width height width height body)
                        'svg t :scale 1.0 :ascent 'center)))
            (when (> (hash-table-count canvas-video--control-images) 128)
              (clrhash canvas-video--control-images))
            (puthash key image canvas-video--control-images)
            image)))))

(defun canvas-video--icon (name color)
  "Draw a 24 pixel icon NAME in COLOR."
  (format
   "<g fill='none' stroke='%s' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'>%s</g>"
   color
   (pcase name
     ('play (format "<path d='M9 5.5 L19 12 L9 18.5 Z' fill='%s' stroke='none'/>" color))
     ('pause (format "<rect x='7' y='6' width='3.5' height='12' rx='1' fill='%s' stroke='none'/><rect x='13.5' y='6' width='3.5' height='12' rx='1' fill='%s' stroke='none'/>" color color))
     ('back "<path d='M7 7 H3 V3 M3 7 A9 9 0 1 1 3.5 17'/><path d='M14 8 H10 V11 H12.5 A2.5 2.5 0 0 1 12.5 16 H10'/>")
     ('forward "<path d='M17 7 H21 V3 M21 7 A9 9 0 1 0 20.5 17'/><path d='M14 8 H10 V11 H12.5 A2.5 2.5 0 0 1 12.5 16 H10'/>")
     ('volume "<path d='M4 9 H8 L13 5 V19 L8 15 H4 Z M16 9 A5 5 0 0 1 16 15 M19 6 A9 9 0 0 1 19 18'/>")
     ('minus "<path d='M6 12 H18'/>")
     ('plus "<path d='M6 12 H18 M12 6 V18'/>")
     ('more (format "<g fill='%s' stroke='none'><circle cx='5' cy='12' r='1.7'/><circle cx='12' cy='12' r='1.7'/><circle cx='19' cy='12' r='1.7'/></g>" color))
     (_ ""))))

(defun canvas-video--button (instance label command &optional icon primary width help)
  "Create a rounded LABEL button for INSTANCE invoking COMMAND.
ICON chooses a vector icon; PRIMARY highlights the main control."
  (let* ((map (make-sparse-keymap))
         (colors (canvas-video--control-colors))
         (surface (nth 0 colors)) (accent (nth 2 colors))
         (foreground (if primary surface (nth 1 colors)))
         (width (or width 30))
         (image (canvas-video--control-image
                 width 32
                 (concat
                  (format "<rect x='0' y='0' width='%d' height='32' rx='9' fill='%s'/>"
                          width (if primary accent surface))
                  (if icon
                      (format "<g transform='translate(%d 4)'>%s</g>"
                              (/ (- width 24) 2) (canvas-video--icon icon foreground))
                    (format "<text x='%d' y='20' text-anchor='middle' font-family='sans-serif' font-size='12' font-weight='600' fill='%s'>%s</text>"
                            (/ width 2) foreground label))))))
    (define-key map [mouse-1]
                (lambda (_event) (interactive "e")
                  (canvas-video--invoke instance command)))
    (propertize (concat " " label " ")
                'display image 'keymap map 'pointer 'hand
                'canvas-video-command command 'mouse-face 'highlight
                'face 'canvas-video-control 'help-echo (or help label))))

(defun canvas-video--seek-fraction (instance fraction)
  "Seek INSTANCE to FRACTION of its duration."
  (let* ((buffer (canvas-video--instance-buffer instance))
         (duration (plist-get (canvas-video--instance-status instance) :duration)))
    (unless (and (buffer-live-p buffer) (numberp duration) (> duration 0))
      (user-error "Video duration is not available yet"))
    (with-current-buffer buffer
      (let ((canvas-video--target instance))
        (canvas-video--current)
        (canvas-video-seek-to (* duration (max 0.0 (min 1.0 fraction))))))))

(defun canvas-video--progress (instance width)
  "Render INSTANCE's clickable progress track at WIDTH pixels."
  (let* ((s (canvas-video--instance-status instance))
         (duration (plist-get s :duration)) (position (plist-get s :position))
         (seekable (and (canvas-video--instance-player instance)
                        (numberp duration) (> duration 0)))
         (fraction (if (and seekable (numberp position))
                       (max 0.0 (min 1.0 (/ (float position) duration))) 0.0))
         (colors (canvas-video--control-colors))
         (track (- width 16)) (filled (round (* fraction track)))
         (image (canvas-video--control-image
                 width 20
                 (concat
                  (format "<rect x='8' y='8' width='%d' height='4' rx='2' fill='%s'/>" track (nth 0 colors))
                  (when (> filled 0)
                    (format "<rect x='8' y='8' width='%d' height='4' rx='2' fill='%s'/>" filled (nth 2 colors)))
                  (when seekable
                    (format "<circle cx='%d' cy='10' r='4' fill='%s'/>" (+ 8 filled) (nth 2 colors))))))
         (map (make-sparse-keymap)))
    (when seekable
      (define-key map [mouse-1]
                  (lambda (event) (interactive "e")
                    (let ((xy (posn-object-x-y (event-start event))))
                      (when xy
                        (canvas-video--seek-fraction instance (/ (- (car xy) 8.0) track)))))))
    (propertize (make-string (max 8 (/ width (max 1 (frame-char-width)))) ?─)
                'display image 'keymap map 'face 'canvas-video-secondary
                'pointer (if seekable 'hand 'arrow)
                'help-echo (if seekable "点击跳转到播放位置" "正在读取视频时长"))))

(defun canvas-video--display-scale (instance)
  "Return INSTANCE's display scale, independent of its render resolution."
  (or (overlay-get (canvas-video--instance-overlay instance) 'canvas-video-display-scale)
      (plist-get (cdr (canvas-video--instance-canvas instance)) :scale) 1.0))

(defun canvas-video--render-canvas (instance)
  "Return INSTANCE's original canvas receiving frames from the native player."
  (or (overlay-get (canvas-video--instance-overlay instance) 'canvas-video-render-canvas)
      (canvas-video--instance-canvas instance)))

(defun canvas-video--refresh-canvas (instance)
  "Scale INSTANCE's latest pixels if needed, then refresh its visible canvas."
  (let ((source (canvas-video--render-canvas instance))
        (canvas (canvas-video--instance-canvas instance)))
    (unless (eq source canvas) (canvas-video--native-scale source canvas))
    (canvas-refresh canvas)))

(defun canvas-video--set-display-scale (instance scale)
  "Scale INSTANCE's pixels into a display canvas without restarting playback."
  (with-current-buffer (canvas-video--instance-buffer instance)
    (let ((canvas-video--target instance)) (canvas-video--current))
    (let* ((width (canvas-video--instance-width instance))
           (height (canvas-video--instance-height instance))
           ;; Keep the controls usable and either displayed edge within 4096.
           (maximum (/ 4096.0 (max width height)))
           (minimum (min maximum (max (/ 240.0 width) (/ 48.0 height))))
           (scale (max minimum (min maximum scale)))
           (overlay (canvas-video--instance-overlay instance))
           (canvas (canvas-video--instance-canvas instance)))
      (unless (and (= scale (canvas-video--display-scale instance))
                   (= 1.0 (or (plist-get (cdr canvas) :scale) 1.0)))
        (unless (fboundp 'canvas-video--native-scale)
          (user-error "Rebuild the video module with make and reload it before resizing"))
        (unless (overlay-get overlay 'canvas-video-render-canvas)
          ;; NS resets the bitmap to its data dimensions on every refresh;
          ;; changing :scale alone changes layout but not the video pixels.
          ;; Retain the original pixels for paused/stopped frames and replay.
          (setf (plist-get (cdr canvas) :scale) 1.0)
          (overlay-put overlay 'canvas-video-render-canvas canvas)
          (setq canvas (list 'image :type 'canvas :id (make-symbol "canvas-video-scaled")
                             :data-width width :data-height height :scale 1.0))
          (setf (canvas-video--instance-canvas instance) canvas)
          (overlay-put overlay 'display canvas))
        (setf (plist-get (cdr canvas) :data-width) (max 1 (round (* width scale)))
              (plist-get (cdr canvas) :data-height) (max 1 (round (* height scale))))
        (overlay-put overlay 'canvas-video-display-scale scale)
        (canvas-video--refresh-canvas instance)
        (canvas-video--update-controls instance)
        (redisplay t)))))

(defun canvas-video--event-frame-xy (event frame)
  "Return EVENT's pixel coordinates in FRAME, even across its windows."
  (let* ((pos (event-end event))
         (window (posn-window pos))
         (xy (posn-x-y pos)))
    (when (and (consp xy) (numberp (car xy)) (numberp (cdr xy)))
      (cond
       ((and (windowp window) (eq (window-frame window) frame))
        (let ((edges (window-inside-pixel-edges window)))
          (cons (+ (car edges) (car xy)) (+ (cadr edges) (cdr xy)))))
       ((eq window frame) xy)))))

(defun canvas-video--drag-resize (instance event)
  "Resize INSTANCE proportionally from mouse-down EVENT until release."
  (let* ((window (posn-window (event-start event)))
         (frame (if (windowp window) (window-frame window) window))
         (start (canvas-video--event-frame-xy event frame))
         (scale (canvas-video--display-scale instance))
         (width (canvas-video--instance-width instance))
         (height (canvas-video--instance-height instance)))
    (when start
      (track-mouse
        (let ((dragging t))
          (while dragging
            (let ((next (read-event)))
              (cond
               ((memq (car-safe next) '(switch-frame select-window)) nil)
               ((memq (car-safe next) '(mouse-movement mouse-1 drag-mouse-1))
                (when-let* ((xy (canvas-video--event-frame-xy next frame)))
                  ;; Use the dominant axis so either horizontal or vertical
                  ;; dragging follows the pointer without cumulative rounding.
                  (let* ((dx (- (car xy) (car start)))
                         (dy (- (cdr xy) (cdr start)))
                         (delta (if (>= (abs dx) (abs dy))
                                    (/ (float dx) width) (/ (float dy) height))))
                    (canvas-video--set-display-scale instance (+ scale delta))))
                (unless (eq (car next) 'mouse-movement) (setq dragging nil)))
               (t
                (setq unread-command-events (cons next unread-command-events)
                      dragging nil))))))))))

(defun canvas-video--resize-handle (instance)
  "Make INSTANCE's proportional resize handle."
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1]
                (lambda (event) (interactive "e")
                  (canvas-video--drag-resize instance event)))
    (define-key map [mouse-1] #'ignore)
    (define-key map [drag-mouse-1] #'ignore)
    (propertize "◢" 'keymap map 'pointer 'hand
                'canvas-video-command 'canvas-video--drag-resize
                'help-echo "按住鼠标左键拖动，等比例调整视频大小"
                'face 'canvas-video-secondary
                'display (canvas-video--control-image
                          20 32
                          (format "<path d='M5 24 L16 13 M10 24 L16 18 M15 24 L16 23' fill='none' stroke='%s' stroke-width='2'/>"
                                  (nth 3 (canvas-video--control-colors)))))))

(defun canvas-video-speed-menu (&optional event)
  "Choose a playback speed for the target video from a menu at EVENT."
  (interactive (list last-input-event))
  (let* ((instance (canvas-video--current))
         (current (or (plist-get (canvas-video--instance-status instance) :speed) 1))
         (speed (x-popup-menu
                 (if (mouse-event-p event) event t)
                 (list "Playback speed"
                       (cons "Playback speed"
                             (mapcar (lambda (value)
                                       (cons (format "%s%gx"
                                                     (if (= current value) "✓  " "    ") value)
                                             value))
                                     '(1 1.25 1.5 2)))))))
    (when speed
      (with-current-buffer (canvas-video--instance-buffer instance)
        (let ((canvas-video--target instance))
          (canvas-video--current)
          (canvas-video-set-speed speed))))))

(defun canvas-video-more (&optional event)
  "Show additional actions for the current video at EVENT."
  (interactive (list last-input-event))
  (let* ((instance (canvas-video--current))
         (action (x-popup-menu
                  (if (mouse-event-p event) event t)
                  '("Video"
                    ("Playback"
                     ("Replay from beginning" . canvas-video-replay)
                     ("Stop playback" . canvas-video-stop)
                     ("Playback speed…" . canvas-video-speed-menu)
                     ("Go to time…" . canvas-video-seek-to)
                     ("Show / hide subtitles" . canvas-video-toggle-subtitles))
                    ("Audio"
                     ("Volume slider…" . canvas-video-volume-popup)
                     ("Mute / unmute" . canvas-video-toggle-mute)
                     ("Volume +5" . canvas-video-volume-up)
                     ("Volume −5" . canvas-video-volume-down))
                    ("Video"
                     ("Remove video" . canvas-video-remove))))))
    (when action (canvas-video--invoke instance action))))

(defun canvas-video--update-controls (instance)
  "Draw compact playback controls without editing the document."
  (let* ((overlay (canvas-video--instance-overlay instance))
         (s (canvas-video--instance-status instance))
         (width (max 180 (round (* (canvas-video--instance-width instance)
                                  (canvas-video--display-scale instance)))))
         (full (>= width 600)) (compact (< width 360))
         (play-p (or (not (canvas-video--instance-player instance))
                     (plist-get s :paused) (plist-get s :eof)))
         (gap (propertize " " 'display '(space :width (6))))
         (clock (if (< width 220)
                    (canvas-video--clock (plist-get s :position))
                  (concat (canvas-video--clock (plist-get s :position))
                          " / " (canvas-video--clock (plist-get s :duration)))))
         (clock-width (+ 12 (* 7 (length clock))))
         (clock-image (canvas-video--control-image
                       clock-width 32
                       (format "<text x='6' y='20' font-family='monospace' font-size='12' fill='%s'>%s</text>"
                               (nth 3 (canvas-video--control-colors)) clock)))
         (left (concat
                (canvas-video--button instance (if play-p "Play" "Pause")
                                      #'canvas-video-toggle-pause (if play-p 'play 'pause) t 36
                                      "播放 / 暂停（SPC）") gap
                (unless (< width 320)
                  (concat (canvas-video--button instance "−5s" #'canvas-video-backward 'back nil nil "后退 5 秒") gap
                          (canvas-video--button instance "+5s" #'canvas-video-forward 'forward nil nil "前进 5 秒") gap))
                (propertize clock 'display clock-image 'face 'canvas-video-secondary)))
         (right (concat
                 (when full (concat (canvas-video--button instance "−" #'canvas-video-volume-down 'minus nil nil "减小音量") gap))
                 (unless (< width 320)
                   (concat (canvas-video--button instance "Volume" #'canvas-video-volume-popup 'volume nil nil
                                                 (format "音量 %.0f%% · 点击拖动调节" (or (plist-get s :volume) 100))) gap))
                 (when full (concat (canvas-video--button instance "+" #'canvas-video-volume-up 'plus nil nil "增大音量") gap))
                 (unless compact
                   (concat (canvas-video--button instance (format "%gx" (or (plist-get s :speed) 1))
                                                 #'canvas-video-speed-menu nil nil 48 "选择播放速度") gap))
                 (canvas-video--button instance "More" #'canvas-video-more 'more nil nil "更多：重播、停止、音量、字幕、移除")
                 gap (canvas-video--resize-handle instance)))
         (left-width (+ 36 6 clock-width (if (< width 320) 0 72)))
         (right-width (+ 56 (if (< width 320) 0 36) (if full 72 0) (if compact 0 54)))
         (spacer (propertize " " 'display `(space :width (,(max 6 (- width left-width right-width)))))))
    (when (overlay-buffer overlay)
      (overlay-put overlay 'after-string
                   (concat "\n" (canvas-video--progress instance width) "\n"
                           left spacer right
                           (when-let* ((text (plist-get s :error)))
                             (concat "\n" (propertize text 'face 'error)))
                           "\n")))))

(defun canvas-video--sync-timer ()
  "Keep one refresh timer while this buffer has active players."
  (if (cl-some #'canvas-video--instance-player canvas-video--instances)
      (unless (timerp canvas-video--timer)
        (setq canvas-video--timer
              (run-at-time 0 (/ 1.0 canvas-video-refresh-rate)
                           #'canvas-video--tick (current-buffer))))
    (when (timerp canvas-video--timer) (cancel-timer canvas-video--timer))
    (setq canvas-video--timer nil)))

(defun canvas-video--close-player (instance)
  "Release INSTANCE's native player, leaving its image intact."
  (when-let* ((player (canvas-video--instance-player instance)))
    (setf (canvas-video--instance-player instance) nil)
    (canvas-video--native-close player)))

(defun canvas-video--dispose (instance)
  "Remove INSTANCE's display and resources, retaining document text."
  (canvas-video--close-player instance)
  (delete-overlay (canvas-video--instance-overlay instance))
  (setq canvas-video--instances (delq instance canvas-video--instances))
  (when (eq instance canvas-video--dedicated) (setq canvas-video--dedicated nil))
  (canvas-video--sync-timer))

(defun canvas-video--cleanup ()
  "Release all players and overlays in this buffer, idempotently."
  (when (timerp canvas-video--timer) (cancel-timer canvas-video--timer))
  (setq canvas-video--timer nil)
  (dolist (instance canvas-video--instances)
    (canvas-video--close-player instance)
    (delete-overlay (canvas-video--instance-overlay instance)))
  (setq canvas-video--instances nil canvas-video--dedicated nil))

(defun canvas-video--cleanup-all ()
  "Release all active players before Emacs exits."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer (canvas-video--cleanup))))
(add-hook 'kill-emacs-hook #'canvas-video--cleanup-all)

(defun canvas-video--intact-p (instance)
  "Return non-nil when INSTANCE's original placeholder is still intact."
  (let ((overlay (canvas-video--instance-overlay instance)))
    (and (eq (overlay-buffer overlay) (current-buffer))
         (save-restriction
           (widen)
           (equal (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay))
                  (canvas-video--instance-placeholder instance))))))

(defun canvas-video--after-change (&rest _)
  "Release videos whose placeholders have been deleted or edited."
  (dolist (instance (copy-sequence canvas-video--instances))
    (unless (canvas-video--intact-p instance) (canvas-video--dispose instance))))

(defun canvas-video--install-hooks ()
  "Install lifecycle hooks without changing this buffer's major mode."
  (add-hook 'kill-buffer-hook #'canvas-video--cleanup nil t)
  (add-hook 'change-major-mode-hook #'canvas-video--cleanup nil t)
  (add-hook 'after-change-functions #'canvas-video--after-change nil t))

(defun canvas-video--visible-p (instance)
  "Return non-nil when INSTANCE is in a visible buffer window."
  (let ((start (overlay-start (canvas-video--instance-overlay instance))))
    (cl-some (lambda (window) (pos-visible-in-window-p start window t))
             (get-buffer-window-list (current-buffer) nil t))))

(defun canvas-video--tick (buffer)
  "Submit visible videos in BUFFER and update their independent states."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (canvas-video--after-change)
      (dolist (instance (copy-sequence canvas-video--instances))
        (when-let* ((player (canvas-video--instance-player instance)))
          (condition-case err
              (progn
                (when (and (canvas-video--visible-p instance)
                           (canvas-video--native-present player (canvas-video--render-canvas instance)))
                  (canvas-video--refresh-canvas instance))
                (when (>= (float-time) (canvas-video--instance-next-status instance))
                  (setf (canvas-video--instance-next-status instance) (+ (float-time) 0.25)
                        (canvas-video--instance-status instance) (canvas-video--native-status player))
                  (when-let* ((text (plist-get (canvas-video--instance-status instance) :error)))
                    (setf (canvas-video--instance-last-error instance) text)
                    (canvas-video--close-player instance)
                    (message "Canvas video: %s" text))
                  (canvas-video--update-controls instance)
                  (force-mode-line-update)))
            (error
             (let ((text (error-message-string err)))
               (setf (canvas-video--instance-last-error instance) text
                     (canvas-video--instance-status instance) (list :error text))
               (canvas-video--close-player instance)
               (canvas-video--update-controls instance)
               (force-mode-line-update)
               (message "Canvas video: %s" text))))))
      (canvas-video--sync-timer))))

(defun canvas-video--send (instance &rest arguments)
  "Queue string ARGUMENTS for INSTANCE's player."
  (unless (canvas-video--instance-player instance)
    (user-error "Video is stopped; use Play or Replay"))
  (canvas-video--native-command (canvas-video--instance-player instance) (vconcat arguments))
  (setf (canvas-video--instance-next-status instance) 0))

(defun canvas-video--command (&rest arguments)
  "Queue ARGUMENTS for the video at point or mouse target."
  (apply #'canvas-video--send (canvas-video--current) arguments))

(defun canvas-video--restart (instance)
  "Restart INSTANCE using its original source and render dimensions."
  (canvas-video--close-player instance)
  (condition-case err
      (progn
        (setf (canvas-video--instance-player instance)
              (canvas-video--native-create (canvas-video--instance-width instance)
                                           (canvas-video--instance-height instance)
                                           (canvas-video--instance-audio instance))
              (canvas-video--instance-status instance) '(:idle t)
              (canvas-video--instance-last-error instance) nil)
        (canvas-video--send instance "loadfile" (canvas-video--instance-source instance) "replace"))
    (error
     (canvas-video--close-player instance)
     (setf (canvas-video--instance-status instance) (list :error (error-message-string err)))
     (canvas-video--update-controls instance)
     (canvas-video--sync-timer)
     (signal (car err) (cdr err))))
  (canvas-video--update-controls instance)
  (canvas-video--sync-timer))

(defun canvas-video--insert-instance (source width height &optional dedicated)
  "Insert SOURCE at point using WIDTH and HEIGHT, optionally DEDICATED.
Return its instance.  Lifecycle hooks track the plain-text placeholder;
display and controls are overlays, so refreshing never modifies buffer text."
  (barf-if-buffer-read-only)
  (canvas-video--check-display width height)
  (let* ((label (format "[video: %s]" (replace-regexp-in-string "[\n\r]" " " source)))
         (instance (canvas-video--make-instance
                    :buffer (current-buffer) :source source :placeholder label
                    :width width :height height :audio canvas-video-audio-output :dedicated dedicated
                    :canvas (list 'image :type 'canvas :id (make-symbol "canvas-video")
                                  :data-width width :data-height height :scale 1.0)))
         (start (point)))
    (condition-case err
        (atomic-change-group
          (insert label)
          ;; Insertions at either edge belong to surrounding text, not video.
          (let ((overlay (make-overlay start (point) nil t nil)))
            (setf (canvas-video--instance-overlay instance) overlay)
            (overlay-put overlay 'canvas-video-instance instance)
            (overlay-put overlay 'display (canvas-video--instance-canvas instance))
            (overlay-put overlay 'help-echo "Video: use controls below or C-c C-v")
            (push instance canvas-video--instances)
            (when dedicated (setq canvas-video--dedicated instance))
            (canvas-video--install-hooks)
            (canvas-video--restart instance)))
      (error
       (when (canvas-video--instance-overlay instance) (canvas-video--dispose instance))
       (signal (car err) (cdr err))))
    instance))

(defun canvas-video--start (source)
  "Open SOURCE in the dedicated player buffer."
  (canvas-video--check-display canvas-video-width canvas-video-height)
  (let ((buffer (get-buffer-create "*canvas-video*")))
    (with-current-buffer buffer
      (canvas-video--cleanup)
      (canvas-video-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (canvas-video--insert-instance source canvas-video-width canvas-video-height t)
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun canvas-video-open (file)
  "Play local FILE in a dedicated video buffer."
  (interactive "fVideo file: ")
  (canvas-video--start (canvas-video--local-file file)))

;;;###autoload
(defun canvas-video-open-url (url)
  "Play media URL in a dedicated video buffer."
  (interactive "sMedia URL: ")
  (canvas-video--start (canvas-video--url url)))

;;;###autoload
(defun canvas-video-insert (file &optional width height)
  "Insert local video FILE at point without changing the major mode.
Optional WIDTH and HEIGHT override inline dimensions.  Return the instance.
The video is a runtime overlay over a plain-text marker; saving or undoing
does not serialize or resurrect the player."
  (interactive "fInsert video file: ")
  (let ((instance (canvas-video--insert-instance (canvas-video--local-file file)
                   (or width canvas-video-inline-width) (or height canvas-video-inline-height))))
    (canvas-video-inline-mode 1)
    instance))

;;;###autoload
(defun canvas-video-insert-url (url &optional width height)
  "Insert media URL at point using optional WIDTH and HEIGHT."
  (interactive "sInsert media URL: ")
  (let ((instance (canvas-video--insert-instance (canvas-video--url url)
                   (or width canvas-video-inline-width) (or height canvas-video-inline-height))))
    (canvas-video-inline-mode 1)
    instance))

(defun canvas-video-toggle-pause ()
  "Toggle the target video's pause, starting stopped or finished videos."
  (interactive)
  (let* ((instance (canvas-video--current)) (player (canvas-video--instance-player instance)))
    (cond ((not player) (canvas-video--restart instance))
          ((plist-get (canvas-video--native-status player) :eof)
           (canvas-video--send instance "seek" "0" "absolute+exact")
           (canvas-video--send instance "set" "pause" "no"))
          (t (canvas-video--send instance "cycle" "pause")))))

(defun canvas-video-seek (seconds)
  "Seek the target video by relative SECONDS."
  (interactive "nSeek by seconds: ")
  (canvas-video--command "seek" (number-to-string seconds) "relative+exact"))
(defun canvas-video-backward ()
  "Seek the target video backward five seconds."
  (interactive) (canvas-video-seek -5))
(defun canvas-video-forward ()
  "Seek the target video forward five seconds."
  (interactive) (canvas-video-seek 5))
(defun canvas-video-seek-to (seconds)
  "Seek the target video to absolute SECONDS."
  (interactive "nGo to second: ")
  (canvas-video--command "seek" (number-to-string (max 0 seconds)) "absolute+exact"))
(defun canvas-video-volume (delta)
  "Change the target video's audio volume by DELTA."
  (interactive "nVolume change: ")
  (canvas-video--command "add" "volume" (number-to-string delta)))
(defun canvas-video-volume-down ()
  "Decrease the target video's volume by five."
  (interactive) (canvas-video-volume -5))
(defun canvas-video-volume-up ()
  "Increase the target video's volume by five."
  (interactive) (canvas-video-volume 5))
(defun canvas-video-toggle-mute ()
  "Toggle muting of the target video."
  (interactive) (canvas-video--command "cycle" "mute"))
(defun canvas-video-set-speed (speed)
  "Set the target video's SPEED between 0.1 and 4."
  (interactive "nPlayback speed: ")
  (unless (and (numberp speed) (<= 0.1 speed 4)) (user-error "Speed must be between 0.1 and 4"))
  (canvas-video--command "set" "speed" (number-to-string speed)))
(defun canvas-video-toggle-subtitles ()
  "Toggle the target video's selected subtitles."
  (interactive) (canvas-video--command "cycle" "sub-visibility"))

(defun canvas-video-replay ()
  "Reopen the target video from the beginning."
  (interactive)
  (let ((instance (canvas-video--current)))
    (if (canvas-video--instance-dedicated instance)
        (canvas-video--start (canvas-video--instance-source instance))
      (canvas-video--restart instance))))

(defun canvas-video-stop ()
  "Release the target player while retaining its image and Play control."
  (interactive)
  (let ((instance (canvas-video--current)))
    (canvas-video--close-player instance)
    (canvas-video--update-controls instance)
    (canvas-video--sync-timer)
    (force-mode-line-update)))

(defun canvas-video-remove ()
  "Remove the target video's placeholder and release its resources."
  (interactive)
  (let* ((instance (canvas-video--current)) (overlay (canvas-video--instance-overlay instance))
         (start (overlay-start overlay)) (end (overlay-end overlay))
         (inhibit-read-only (or inhibit-read-only (canvas-video--instance-dedicated instance))))
    (barf-if-buffer-read-only)
    (save-restriction
      (widen)
      ;; after-change releases the instance only after a successful deletion.
      (delete-region start end))))

(defun canvas-video-quit ()
  "Close a dedicated player, or remove just the inline video at point."
  (interactive)
  (if (derived-mode-p 'canvas-video-mode) (quit-window t) (canvas-video-remove)))

(defvar canvas-video-control-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'canvas-video-toggle-pause)
    (define-key map (kbd "<left>") #'canvas-video-backward)
    (define-key map (kbd "<right>") #'canvas-video-forward)
    (define-key map (kbd "C-<left>") (lambda () (interactive) (canvas-video-seek -30)))
    (define-key map (kbd "C-<right>") (lambda () (interactive) (canvas-video-seek 30)))
    (define-key map (kbd "+") #'canvas-video-volume-up)
    (define-key map (kbd "-") #'canvas-video-volume-down)
    (define-key map (kbd "m") #'canvas-video-toggle-mute)
    (define-key map (kbd "v") #'canvas-video-set-speed)
    (define-key map (kbd "j") #'canvas-video-seek-to)
    (define-key map (kbd "S") #'canvas-video-toggle-subtitles)
    (define-key map (kbd "g") #'canvas-video-replay)
    (define-key map (kbd "s") #'canvas-video-stop)
    (define-key map (kbd "q") #'canvas-video-remove)
    map))
(defvar canvas-video-inline-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-v") canvas-video-control-map)
    map))

(define-minor-mode canvas-video-inline-mode
  "Control videos embedded in editable text with the C-c C-v prefix.
Commands target the video at point.  Mouse controls target their own video.
Disabling this mode removes inline overlays and stops their players, leaving
plain-text placeholders in the document."
  :lighter " Video" :keymap canvas-video-inline-mode-map
  (if canvas-video-inline-mode
      (canvas-video--install-hooks)
    (dolist (instance (copy-sequence canvas-video--instances))
      (unless (canvas-video--instance-dedicated instance) (canvas-video--dispose instance)))))

(defvar canvas-video-mode-map
  (let ((map (copy-keymap canvas-video-control-map)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "o") #'canvas-video-open)
    (define-key map (kbd "q") #'canvas-video-quit)
    map))
(define-derived-mode canvas-video-mode special-mode "Canvas Video"
  "Major mode for the dedicated libmpv canvas player.
\{canvas-video-mode-map}"
  (setq-local cursor-type nil truncate-lines t buffer-undo-list t
              mode-line-format '(" " mode-name " " mode-line-buffer-identification)
              header-line-format '(:eval (canvas-video--header)))
  (canvas-video--install-hooks))
(provide 'canvas-video)
;;; canvas-video.el ends here
