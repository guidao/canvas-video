;;; canvas-video-telega.el --- Open telega videos with Canvas -*- lexical-binding: t; -*-

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


;; Version: 0.1.1
;; Package-Requires: ((emacs "32.0.50") (canvas-video "0.2.0"))

;;; Commentary:
;; (require 'canvas-video-telega)
;; (canvas-video-telega-mode 1)
;; Normal video messages (including video link previews) are downloaded by
;; telega and opened in the dedicated canvas player.  Does not connect to
;; Telegram, change telega customization values, or modify chat text.

;;; Code:
(require 'canvas-video)

;; Special variables owned by telega.  Their bindings are scoped to each
;; operation: download callbacks may execute after the open call returns.
(defvar telega-open-message-as-file)
(defvar telega-open-file-function)
(declare-function telega-ffplay-stop "telega-ffplay" (&optional proc stop-reason))

(defun canvas-video-telega--ffplay-video (original filename ffplay-args
                                                &optional callback initial-progress)
  "Route external visual playback of FILENAME to Canvas.
Telegram MP4 animations bypass the normal video-message entry point.
Audio-only invocations and callers requiring ffplay process CALLBACKs
retain ORIGINAL behavior, including their INITIAL-PROGRESS value."
  (let ((options (split-string (or ffplay-args "") "[ \t\n]+" t)))
    (if (and (stringp filename)
             (member (downcase (or (file-name-extension filename) ""))
                     '("mp4" "m4v" "webm" "mkv" "mov" "avi" "ogv" "gif"))
             (not (member "-nodisp" options))
             (not callback))
        (progn
          (when (fboundp 'telega-ffplay-stop) (telega-ffplay-stop))
          (let ((buffer (canvas-video-open filename)))
            (with-current-buffer buffer
              ;; Telegram's external animations normally use `-loop 0'.
              (when (equal (cadr (member "-loop" options)) "0")
                (canvas-video--command "set" "loop-file" "inf"))
              (when (member "-an" options)
                (canvas-video--command "set" "mute" "yes")))
            buffer))
      (funcall original filename ffplay-args callback initial-progress))))

(defun canvas-video-telega--open-video (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS using telega's complete-file download path."
  (let ((telega-open-message-as-file
         (cons 'video (and (boundp 'telega-open-message-as-file)
                          telega-open-message-as-file))))
    (apply original arguments)))

(defun canvas-video-telega--play-video (original &rest arguments)
  "Let ORIGINAL open downloaded video ARGUMENTS using Canvas.
Bind both options here again because this call may be a download callback.
Keep telega's own open-file hooks and message back-reference handling."
  (let ((telega-open-message-as-file
         (cons 'video (and (boundp 'telega-open-message-as-file)
                          telega-open-message-as-file)))
        (telega-open-file-function #'canvas-video-open))
    (apply original arguments)))

;;;###autoload
(define-minor-mode canvas-video-telega-mode
  "Open telega video messages in the dedicated canvas-video player.
Videos download completely before playback.  External MP4/GIF animations
also use Canvas; inline animation previews, audio, voice-note process
callbacks and ordinary document opening retain telega's behavior.
Disable this mode to restore normal video opening.
This mode can be enabled before or after telega is loaded."
  :global t
  :group 'canvas-video
  (if canvas-video-telega-mode
      (progn
        (advice-add 'telega-msg-open-video :around #'canvas-video-telega--open-video)
        (advice-add 'telega-msg--play-video :around #'canvas-video-telega--play-video)
        (advice-add 'telega-ffplay-run :around #'canvas-video-telega--ffplay-video))
    (advice-remove 'telega-msg-open-video #'canvas-video-telega--open-video)
    (advice-remove 'telega-msg--play-video #'canvas-video-telega--play-video)
    (advice-remove 'telega-ffplay-run #'canvas-video-telega--ffplay-video)))

(provide 'canvas-video-telega)
;;; canvas-video-telega.el ends here
