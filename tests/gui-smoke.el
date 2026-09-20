;;; gui-smoke.el --- Isolated graphical smoke test -*- lexical-binding: t; -*-

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


;; Run only in a fresh Emacs: make check-gui.  This script exits Emacs.
(require 'canvas-video)
(setq canvas-video-width 640
      canvas-video-height 360
      canvas-video-audio-output "null")
(defvar canvas-video-gui--fixture
  (expand-file-name "fixture.mkv" (file-name-directory load-file-name)))
(defvar canvas-video-gui--result
  (expand-file-name "gui-result.log" (file-name-directory load-file-name)))
(defvar canvas-video-gui--player nil)
(defvar canvas-video-gui--timer nil)

(defun canvas-video-gui--finish (error)
  (with-temp-file canvas-video-gui--result
    (insert (if error (format "FAIL: %S\n" error)
              "PASS: dedicated and inline canvas redisplay, mixed text/images, independent controls, editing, deletion and cleanup\n")))
  (kill-emacs (if error 1 0)))

(defun canvas-video-gui--schedule (delay function)
  (run-at-time
   delay nil
   (lambda ()
     (condition-case err
         (funcall function)
       (error (canvas-video-gui--finish err))))))

(defun canvas-video-gui--start ()
  (set-frame-size (selected-frame) 110 45)
  (canvas-video-open canvas-video-gui--fixture)
  (delete-other-windows)
  (canvas-video-gui--schedule 1 #'canvas-video-gui--playing))

(defun canvas-video-gui--playing ()
  (with-current-buffer "*canvas-video*"
    (cl-assert (display-graphic-p))
    (cl-assert (get-buffer-window (current-buffer)))
    (cl-assert (equal (image-size (canvas-video--instance-canvas canvas-video--dedicated) t) '(640 . 360)))
    (cl-assert (> (plist-get (canvas-video--native-status (canvas-video--instance-player canvas-video--dedicated)) :frames) 5))
    (cl-assert (null (canvas-video--instance-last-error canvas-video--dedicated)))
    (redisplay t)
    (setq canvas-video-gui--player (canvas-video--instance-player canvas-video--dedicated)
          canvas-video-gui--timer canvas-video--timer)
    (canvas-video-toggle-pause))
  (canvas-video-gui--schedule 0.3 #'canvas-video-gui--paused))

(defun canvas-video-gui--paused ()
  (with-current-buffer "*canvas-video*"
    (cl-assert (plist-get (canvas-video--native-status (canvas-video--instance-player canvas-video--dedicated)) :paused))
    ;; Find the actual resize handle through GUI hit testing, then send the
    ;; gesture through the command loop so after-string bindings are exercised.
    (redisplay t)
    (let* ((window (get-buffer-window (current-buffer)))
           (pos (catch 'handle
                  (cl-loop for y from 0 below (window-pixel-height window) by 4 do
                           (cl-loop for x from 0 below (window-pixel-width window) by 4 do
                                    (let* ((p (posn-at-x-y x y window))
                                           (s (and p (posn-string p))))
                                      (when (and s
                                                 (eq (get-text-property (cdr s) 'canvas-video-command (car s))
                                                     'canvas-video--drag-resize))
                                        (throw 'handle p))))))))
      (cl-assert pos)
      (let ((end (copy-tree pos)))
        (setf (nth 2 end) (cons (+ (car (posn-x-y pos)) 160) (cdr (posn-x-y pos))))
        (setq unread-command-events
              (append (list (list 'down-mouse-1 pos)
                            (list 'mouse-movement end)
                            (list 'drag-mouse-1 pos end))
                      unread-command-events)))))
  (canvas-video-gui--schedule 0.3 #'canvas-video-gui--resized))

(defun canvas-video-gui--resized ()
  (with-current-buffer "*canvas-video*"
    (cl-assert (eq canvas-video-gui--player (canvas-video--instance-player canvas-video--dedicated)))
    (cl-assert (plist-get (canvas-video--native-status canvas-video-gui--player) :paused))
    (cl-assert (equal (image-size (canvas-video--instance-canvas canvas-video--dedicated) t) '(800 . 450)))
    (let ((canvas (canvas-video--instance-canvas canvas-video--dedicated)))
      (cl-assert (= 800 (plist-get (cdr canvas) :data-width)))
      (cl-assert (= 450 (plist-get (cdr canvas) :data-height)))
      (cl-assert (= 1.0 (plist-get (cdr canvas) :scale))))
    (canvas-video-seek-to 2.5))
  (canvas-video-gui--schedule 0.4 #'canvas-video-gui--seeked))

(defun canvas-video-gui--seeked ()
  (with-current-buffer "*canvas-video*"
    (let ((s (canvas-video--native-status (canvas-video--instance-player canvas-video--dedicated))))
      (cl-assert (< (abs (- (plist-get s :position) 2.5)) 0.15)))
    (cl-assert (null (canvas-video--instance-last-error canvas-video--dedicated)))
    (canvas-video-toggle-pause))
  (canvas-video-gui--schedule 0.4 #'canvas-video-gui--reopen))

(defun canvas-video-gui--reopen ()
  (kill-buffer "*canvas-video*")
  (cl-assert (not (memq canvas-video-gui--timer timer-list)))
  (cl-assert
   (condition-case nil
       (progn (canvas-video--native-status canvas-video-gui--player) nil)
     (error t)))
  (canvas-video-open canvas-video-gui--fixture)
  (canvas-video-gui--schedule 0.7 #'canvas-video-gui--done))

(defun canvas-video-gui--done ()
  (with-current-buffer "*canvas-video*"
    (cl-assert (canvas-video--instance-player canvas-video--dedicated))
    (cl-assert (null (canvas-video--instance-last-error canvas-video--dedicated)))
    (cl-assert (> (plist-get (canvas-video--native-status (canvas-video--instance-player canvas-video--dedicated)) :frames) 5)))
  (canvas-video-gui--mixed-start))

(canvas-video-gui--schedule 0.5 #'canvas-video-gui--start)
(run-at-time 20 nil (lambda () (canvas-video-gui--finish '(error "GUI test timed out"))))

(defvar canvas-video-gui--first nil)
(defvar canvas-video-gui--second nil)
(defvar canvas-video-gui--document nil)

(defun canvas-video-gui--mixed-start ()
  (set-frame-size (selected-frame) 110 60)
  (switch-to-buffer (get-buffer-create "*canvas-video-mixed-test*"))
  (text-mode)
  (insert "Text, picture and two independent videos\n\n")
  (insert-image (create-image
                 "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='30'><rect width='100' height='30' fill='green'/></svg>"
                 'svg t))
  (insert "\nFirst video:\n")
  (setq canvas-video-gui--first (canvas-video-insert canvas-video-gui--fixture 320 180))
  (insert "\nAn editable paragraph between two videos.\n")
  (setq canvas-video-gui--second (canvas-video-insert canvas-video-gui--fixture 320 180))
  (insert "\nMore text after the video.\n")
  (goto-char (point-min))
  (redisplay t)
  (canvas-video-gui--schedule 0.7 #'canvas-video-gui--mixed-playing))

(defun canvas-video-gui--click (instance command)
  (let* ((text (overlay-get (canvas-video--instance-overlay instance) 'after-string))
         (offset (text-property-any 0 (length text) 'canvas-video-command command text))
         (map (get-text-property offset 'keymap text)))
    (funcall (lookup-key map [mouse-1]) nil)))

(defun canvas-video-gui--mixed-playing ()
  (with-current-buffer "*canvas-video-mixed-test*"
    (cl-assert (eq major-mode 'text-mode))
    (cl-assert (not buffer-read-only))
    (cl-assert (= (length canvas-video--instances) 2))
    (dolist (instance canvas-video--instances)
      (cl-assert (equal (image-size (canvas-video--instance-canvas instance) t) '(320 . 180)))
      (cl-assert (> (plist-get (canvas-video--native-status
                               (canvas-video--instance-player instance)) :frames) 5))
      (cl-assert (null (canvas-video--instance-last-error instance))))
    ;; Editing normal text must keep both video overlays and players intact.
    (goto-char (point-min))
    (insert "Edited while both videos were playing.\n")
    (cl-assert (cl-every #'canvas-video--intact-p canvas-video--instances))
    (goto-char (overlay-start (canvas-video--instance-overlay canvas-video-gui--second)))
    (canvas-video-gui--click canvas-video-gui--first #'canvas-video-toggle-pause)
    (set-buffer-modified-p nil)
    (setq canvas-video-gui--document (buffer-string)))
  (canvas-video-gui--schedule 0.3 #'canvas-video-gui--mixed-paused))

(defun canvas-video-gui--mixed-paused ()
  (with-current-buffer "*canvas-video-mixed-test*"
    (cl-assert (not (buffer-modified-p)))
    (cl-assert (equal canvas-video-gui--document (buffer-string)))
    (cl-assert (plist-get (canvas-video--native-status
                          (canvas-video--instance-player canvas-video-gui--first)) :paused))
    (cl-assert (not (plist-get (canvas-video--native-status
                               (canvas-video--instance-player canvas-video-gui--second)) :paused)))
    (let ((canvas-video--target canvas-video-gui--first))
      (canvas-video-volume-popup))
    (cl-assert (frame-live-p canvas-video-volume--frame))
    (cl-assert (eq (frame-parent canvas-video-volume--frame) (selected-frame)))
    (with-current-buffer canvas-video-volume--buffer
      (cl-assert (equal (image-size (get-text-property (point-min) 'display) t)
                        '(260 . 76))))
    ;; Exercise the command loop: macOS queues a frame switch before the
    ;; click.  Directly calling --set-at would miss premature dismissal.
    (redisplay t)
    (let* ((frame canvas-video-volume--frame)
           (pos (posn-at-x-y 130 50 (frame-root-window frame))))
      (cl-assert (posn-object-x-y pos))
      (setq unread-command-events
            (append (list (list 'switch-frame frame)
                          (list 'down-mouse-1 pos) (list 'mouse-1 pos))
                    unread-command-events))))
  (canvas-video-gui--schedule 0.3 #'canvas-video-gui--mixed-volume))

(defun canvas-video-gui--mixed-volume ()
  (with-current-buffer "*canvas-video-mixed-test*"
    (cl-assert (frame-live-p canvas-video-volume--frame))
    (cl-assert (= 50 (plist-get (canvas-video--native-status
                                (canvas-video--instance-player canvas-video-gui--first)) :volume)))
    (cl-assert (= 100 (plist-get (canvas-video--native-status
                                 (canvas-video--instance-player canvas-video-gui--second)) :volume)))
    (canvas-video-volume-hide)
    (cl-assert (null canvas-video-volume--frame))
    (cl-assert (null canvas-video-volume--timer))
    ;; Removing the first via its button must not delete the current (second).
    (let ((player (canvas-video--instance-player canvas-video-gui--first)))
      (cl-letf (((symbol-function 'x-popup-menu)
                 (lambda (&rest _) 'canvas-video-remove)))
        (canvas-video-gui--click canvas-video-gui--first #'canvas-video-more))
      (cl-assert (condition-case nil
                     (progn (canvas-video--native-status player) nil) (error t))))
    (cl-assert (= (length canvas-video--instances) 1))
    (cl-assert (eq (car canvas-video--instances) canvas-video-gui--second))
    (cl-assert (canvas-video--instance-player canvas-video-gui--second)))
  (canvas-video-gui--schedule 0.3 #'canvas-video-gui--mixed-done))

(defun canvas-video-gui--mixed-done ()
  (with-current-buffer "*canvas-video-mixed-test*"
    (let ((player (canvas-video--instance-player canvas-video-gui--second))
          (timer canvas-video--timer))
      (fundamental-mode)
      (cl-assert (null canvas-video--instances))
      (cl-assert (not (memq timer timer-list)))
      (cl-assert (condition-case nil
                     (progn (canvas-video--native-status player) nil) (error t)))))
  (kill-buffer "*canvas-video-mixed-test*")
  (kill-buffer "*canvas-video*")
  (canvas-video-gui--finish nil))
