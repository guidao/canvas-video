;;; canvas-video-volume.el --- Floating volume slider -*- lexical-binding: t; -*-
;;; Commentary:
;; A child frame containing an SVG slider, scoped to one video instance.
;;; Code:
(require 'canvas-video)
(declare-function canvas-video--native-status "canvas-video-module" (player))

(defvar canvas-video-volume--frame nil)
(defvar canvas-video-volume--buffer nil)
(defvar canvas-video-volume--instance nil)
(defvar canvas-video-volume--timer nil)
(defvar canvas-video-volume--exit nil)

(defun canvas-video-volume-hide ()
  "Close the volume popup and release its resources."
  (interactive)
  (let ((frame canvas-video-volume--frame)
        (buffer canvas-video-volume--buffer)
        (exit canvas-video-volume--exit))
    (setq canvas-video-volume--frame nil canvas-video-volume--buffer nil
          canvas-video-volume--instance nil canvas-video-volume--exit nil)
    (when (timerp canvas-video-volume--timer)
      (cancel-timer canvas-video-volume--timer))
    (setq canvas-video-volume--timer nil)
    (remove-hook 'pre-command-hook #'canvas-video-volume--dismiss)
    (when exit (funcall exit))
    (when (frame-live-p frame) (delete-frame frame t))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun canvas-video-volume--live-p ()
  "Whether the popup still belongs to a displayed, active video."
  (let ((instance canvas-video-volume--instance))
    (and instance (frame-live-p canvas-video-volume--frame)
         (buffer-live-p (canvas-video--instance-buffer instance))
         (canvas-video--instance-player instance)
         (with-current-buffer (canvas-video--instance-buffer instance)
           (and (memq instance canvas-video--instances)
                (get-buffer-window (current-buffer) t))))))

(defun canvas-video-volume--dismiss ()
  "Dismiss the popup before commands outside its child frame."
  (let* ((event last-input-event)
         (window (and (mouse-event-p event) (posn-window (event-start event))))
         (frame (if (windowp window) (window-frame window) window)))
    ;; Clicking a child frame first queues a switch-frame event.  This is
    ;; window-system bookkeeping, not a click outside the popup.  Keep the
    ;; frame alive until the following mouse event can reach its slider.
    (unless (or (memq (car-safe event) '(switch-frame select-window mouse-movement))
                (and frame (eq frame canvas-video-volume--frame)))
      (canvas-video-volume-hide))))

(defun canvas-video-volume--draw (volume)
  "Draw the popup slider at VOLUME percent."
  (when (buffer-live-p canvas-video-volume--buffer)
    (let* ((colors (canvas-video--control-colors))
           (x (+ 20 (* 2.2 (max 0 (min 100 volume)))))
           (image (canvas-video--control-image
                   260 76
                   (format "<rect width='260' height='76' rx='12' fill='%s'/><text x='20' y='24' font-family='sans-serif' font-size='11' font-weight='600' fill='%s'>VOLUME</text><text x='240' y='24' text-anchor='end' font-family='monospace' font-size='12' fill='%s'>%.0f%%</text><path d='M20 50 H240' stroke='%s' stroke-width='5' stroke-linecap='round' opacity='.2'/><path d='M20 50 H%.1f' stroke='%s' stroke-width='5' stroke-linecap='round'/><circle cx='%.1f' cy='50' r='7' fill='%s'/>"
                           (nth 0 colors) (nth 3 colors) (nth 1 colors) volume (nth 1 colors)
                           x (nth 2 colors) x (nth 2 colors)))))
      (with-current-buffer canvas-video-volume--buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "Volume" 'display image 'pointer 'hand
                              'help-echo "拖动调节音量 · Esc 关闭"))
          (goto-char (point-min))
          (set-buffer-modified-p nil))))))

(defun canvas-video-volume--refresh ()
  "Refresh volume and close a popup whose video has disappeared."
  (if (not (canvas-video-volume--live-p)) (canvas-video-volume-hide)
    (condition-case nil
        (canvas-video-volume--draw
         (or (plist-get (canvas-video--native-status
                         (canvas-video--instance-player canvas-video-volume--instance))
                        :volume) 100))
      (error (canvas-video-volume-hide)))))

(defun canvas-video-volume--set-at (instance x)
  "Set INSTANCE's volume from slider pixel X, clamping at its ends."
  (unless (and instance (buffer-live-p (canvas-video--instance-buffer instance)))
    (user-error "This video was removed"))
  (with-current-buffer (canvas-video--instance-buffer instance)
    (let ((canvas-video--target instance)
          (volume (round (* 100 (/ (- x 20.0) 220)))))
      (canvas-video--current)
      (setq volume (max 0 (min 100 volume)))
      (canvas-video--send instance "set" "volume" (number-to-string volume))
      ;; Moving a volume slider should also restore previously muted audio.
      (canvas-video--send instance "set" "mute" "no")
      (canvas-video-volume--draw volume))))

(defun canvas-video-volume--event-x (event)
  "Translate EVENT to slider coordinates, including drags outside the popup."
  (let* ((pos (event-end event)) (window (posn-window pos))
         (frame (if (windowp window) (window-frame window) window))
         (xy (posn-x-y pos)))
    (when (and (framep frame) (consp xy) (numberp (car xy)))
      (+ (car xy) (if (windowp window) (car (window-inside-pixel-edges window)) 0)
         (- (car (frame-position frame))
            (car (frame-position canvas-video-volume--frame)))))))

(defun canvas-video-volume--drag (event)
  "Adjust volume while tracking the mouse from down EVENT through release."
  (interactive "e")
  (let ((instance canvas-video-volume--instance)
        (xy (posn-object-x-y (event-start event))))
    (when (and xy (>= (cdr xy) 34))
      (unwind-protect
          (progn
            (when (timerp canvas-video-volume--timer)
              (cancel-timer canvas-video-volume--timer)
              (setq canvas-video-volume--timer nil))
            (canvas-video-volume--set-at instance (car xy))
            (track-mouse
              (let ((dragging t))
                (while dragging
                  (let ((next (read-event)))
                    (cond
                     ((memq (car-safe next) '(switch-frame select-window)) nil)
                     ((memq (car-safe next) '(mouse-movement mouse-1 drag-mouse-1))
                        (progn
                          (when-let* ((x (canvas-video-volume--event-x next)))
                            (canvas-video-volume--set-at instance x))
                          (unless (eq (car next) 'mouse-movement) (setq dragging nil))))
                     (t
                      (setq unread-command-events (cons next unread-command-events)
                            dragging nil))))))))
        (when (canvas-video-volume--live-p)
          (setq canvas-video-volume--timer
                (run-at-time 0.2 0.25 #'canvas-video-volume--refresh)))))))

;;;###autoload
(defun canvas-video-volume-popup (&optional event)
  "Show a draggable volume slider for the target video near EVENT."
  (interactive (list last-input-event))
  (let* ((instance (canvas-video--current))
         (pos (and (mouse-event-p event) (event-start event)))
         (window (if (and pos (windowp (posn-window pos)))
                     (posn-window pos) (selected-window)))
         (parent (window-frame window))
         (edges (window-inside-pixel-edges window))
         (xy (if pos (posn-x-y pos) '(20 . 100)))
         (x (+ (car edges) (car xy)))
         (y (+ (nth 1 edges) (cdr xy))))
    (unless (canvas-video--instance-player instance)
      (user-error "Start playback before adjusting volume"))
    (canvas-video-volume-hide)
    (condition-case err
        (progn
          (setq canvas-video-volume--instance instance
                canvas-video-volume--buffer (generate-new-buffer " *canvas-video-volume*"))
          (with-current-buffer canvas-video-volume--buffer
            (setq-local mode-line-format nil header-line-format nil
                        cursor-type nil truncate-lines t
                        left-margin-width 0 right-margin-width 0
                        buffer-read-only t)
            (let ((map (make-sparse-keymap)))
              (define-key map [down-mouse-1] #'canvas-video-volume--drag)
              (define-key map [mouse-1] #'ignore)
              (define-key map [drag-mouse-1] #'ignore)
              (define-key map (kbd "ESC") #'canvas-video-volume-hide)
              (use-local-map map)))
          (let ((background (car (canvas-video--control-colors))))
            (setq canvas-video-volume--frame
                  (make-frame `((parent-frame . ,parent) (minibuffer . nil)
                                (undecorated . t) (no-accept-focus . t)
                                (visibility . nil) (skip-taskbar . t)
                                (border-width . 0) (internal-border-width . 0)
                                (left-fringe . 0) (right-fringe . 0)
                                (menu-bar-lines . 0) (tool-bar-lines . 0)
                                (tab-bar-lines . 0) (vertical-scroll-bars . nil)
                                (horizontal-scroll-bars . nil) (unsplittable . t)
                                (no-other-frame . t) (desktop-dont-save . t)
                                (background-color . ,background)))))
          (set-window-buffer (frame-root-window canvas-video-volume--frame)
                             canvas-video-volume--buffer)
          (set-frame-size canvas-video-volume--frame 260 76 t)
          (set-frame-position canvas-video-volume--frame
                              (max 0 (min (- (frame-pixel-width parent) 260) (- x 130)))
                              (max 0 (min (- (frame-pixel-height parent) 76)
                                          (if (> y 90) (- y 86) (+ y 36)))))
          (canvas-video-volume--refresh)
          (make-frame-visible canvas-video-volume--frame)
          (select-frame parent 'norecord)
          (add-hook 'pre-command-hook #'canvas-video-volume--dismiss)
          (let ((map (make-sparse-keymap)))
            (define-key map [escape] #'canvas-video-volume-hide)
            (define-key map (kbd "C-g") #'canvas-video-volume-hide)
            (setq canvas-video-volume--exit
                  (set-transient-map map (lambda () (frame-live-p canvas-video-volume--frame)))))
          (setq canvas-video-volume--timer
                (run-at-time 0.25 0.25 #'canvas-video-volume--refresh)))
      (error (canvas-video-volume-hide) (signal (car err) (cdr err))))))

(provide 'canvas-video-volume)
;;; canvas-video-volume.el ends here
