;;; canvas-video-telega-test.el --- Routing tests without Telegram -*- lexical-binding: t; -*-
(require 'ert)
(require 'canvas-video-telega)

;; Model telega-customize's special variables without loading its client.
(defvar telega-open-message-as-file nil)
(defvar telega-open-file-function #'find-file)

(ert-deftest canvas-video-telega-download-scope ()
  (let ((telega-open-message-as-file '(audio))
        (telega-open-file-function #'find-file))
    (should
     (eq (canvas-video-telega--open-video
          (lambda (&rest args)
            (should (equal args '(message preview)))
            (should (memq 'video telega-open-message-as-file))
            (should (memq 'audio telega-open-message-as-file))
            (should (eq telega-open-file-function #'find-file))
            'download-queued)
          'message 'preview)
         'download-queued))
    (should (equal telega-open-message-as-file '(audio)))))

(ert-deftest canvas-video-telega-asynchronous-playback-scope ()
  (let ((telega-open-message-as-file nil)
        (telega-open-file-function #'find-file)
        opened)
    ;; Simulate telega's later download callback, outside the open binding.
    (cl-letf (((symbol-function 'canvas-video-open)
               (lambda (file) (setq opened file) 'player-buffer)))
      (should
       (eq (canvas-video-telega--play-video
            (lambda (msg file &optional callback)
              (should (eq msg 'message))
              (should (eq callback 'done))
              (should (memq 'video telega-open-message-as-file))
              (funcall telega-open-file-function file))
            'message "/tmp/video without extension" 'done)
           'player-buffer)))
    (should (equal opened "/tmp/video without extension"))
    (should-not telega-open-message-as-file)
    (should (eq telega-open-file-function #'find-file))))

(ert-deftest canvas-video-telega-toggle-and-error-restoration ()
  (let ((telega-open-message-as-file '(photo))
        (telega-open-file-function #'find-file))
    (unwind-protect
        (progn
          (canvas-video-telega-mode 1)
          (canvas-video-telega-mode 1)
          (should (advice-member-p #'canvas-video-telega--open-video 'telega-msg-open-video))
          (should (advice-member-p #'canvas-video-telega--play-video 'telega-msg--play-video))
          (should (advice-member-p #'canvas-video-telega--ffplay-video 'telega-ffplay-run))
          (should-error (canvas-video-telega--play-video
                         (lambda (&rest _) (error "Cannot open video"))))
          (should (equal telega-open-message-as-file '(photo)))
          (should (eq telega-open-file-function #'find-file)))
      (canvas-video-telega-mode -1))
    (should-not (advice-member-p #'canvas-video-telega--open-video 'telega-msg-open-video))
    (should-not (advice-member-p #'canvas-video-telega--play-video 'telega-msg--play-video))
    (should-not (advice-member-p #'canvas-video-telega--ffplay-video 'telega-ffplay-run))))

(ert-deftest canvas-video-telega-external-animation-loop ()
  (with-temp-buffer
    (let ((buffer (current-buffer)) opened commands stopped)
      (cl-letf (((symbol-function 'canvas-video-open)
                 (lambda (file) (setq opened file) buffer))
                ((symbol-function 'canvas-video--command)
                 (lambda (&rest args) (push args commands)))
                ((symbol-function 'telega-ffplay-stop)
                 (lambda (&rest _) (setq stopped t))))
        (should
         (eq buffer (canvas-video-telega--ffplay-video
                     (lambda (&rest _) (ert-fail "External player must not run"))
                     "/tmp/downloaded animation.MP4" "-loop 0 -an")))
        (should (equal opened "/tmp/downloaded animation.MP4"))
        (should stopped)
        (should (member '("set" "loop-file" "inf") commands))
        (should (member '("set" "mute" "yes") commands))))))

(ert-deftest canvas-video-telega-ffplay-preserves-audio-and-process-contract ()
  (dolist (args '(("/tmp/voice.ogg" "-nodisp" callback 3)
                  ("/tmp/audio.mp4" "-nodisp" nil nil)
                  ("/tmp/video.mp4" "" callback 10)
                  ("/tmp/file.unknown" "" nil nil)))
    (let (forwarded)
      (cl-letf (((symbol-function 'canvas-video-open)
                 (lambda (&rest _) (ert-fail "Original player must be preserved"))))
        (should
         (eq (apply #'canvas-video-telega--ffplay-video
                    (lambda (&rest actual) (setq forwarded actual) 'process) args)
             'process))
        (should (equal forwarded args))))))
