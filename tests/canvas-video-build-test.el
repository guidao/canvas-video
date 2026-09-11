;;; canvas-video-build-test.el --- Build command tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'canvas-video)

(defmacro canvas-video-build-test--with-directory (&rest body)
  "Run BODY in a temporary source directory, then clean up its build process."
  (declare (indent 0) (debug t))
  `(let ((canvas-video--directory
          (file-name-as-directory (make-temp-file "canvas-video build " t)))
         (canvas-video-emacs-include nil))
     (unwind-protect
         (let ((default-directory canvas-video--directory)) ,@body)
       (when-let* ((buffer (get-buffer "*canvas-video-build*")))
         (when-let* ((process (get-buffer-process buffer)))
           (delete-process process))
         (kill-buffer buffer))
       (delete-directory canvas-video--directory t))))

(defun canvas-video-build-test--wait (buffer)
  "Wait for BUFFER's compilation and return its exit code."
  (let ((process (get-buffer-process buffer))
        (deadline (+ (float-time) 10)))
    (should process)
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.05))
    (should-not (process-live-p process))
    (process-exit-status process)))

(ert-deftest canvas-video-build-directory-header-and-force ()
  (skip-unless (executable-find "make"))
  (canvas-video-build-test--with-directory
    (let ((canvas-video-emacs-include (expand-file-name "header files")))
      (make-directory canvas-video-emacs-include)
      (with-temp-file (expand-file-name "emacs-module.h" canvas-video-emacs-include))
      (with-temp-file "Makefile"
        (insert ".PHONY: all\nall: canvas-video-module$(MODULE_SUFFIX)\n"
                "canvas-video-module$(MODULE_SUFFIX):\n"
                "\t@printf 'built\\n' >> builds\n"
                "\t@printf '%s' \"$(EMACS_INCLUDE)\" > header-dir\n"
                "\t@touch $@\n"))
      ;; Invoke from another buffer directory, as an installed package is used.
      (let* ((default-directory temporary-file-directory)
             (buffer (canvas-video-build)))
        (should (equal (buffer-local-value 'default-directory buffer)
                       canvas-video--directory))
        (should (= 0 (canvas-video-build-test--wait buffer))))
      (should (file-exists-p (concat "canvas-video-module" module-file-suffix)))
      (should (equal (with-temp-buffer
                       (insert-file-contents "header-dir") (buffer-string))
                     canvas-video-emacs-include))
      (should (= 0 (canvas-video-build-test--wait (canvas-video-build))))
      (should (equal (with-temp-buffer
                       (insert-file-contents "builds") (buffer-string))
                     "built\n"))
      (should (= 0 (canvas-video-build-test--wait (canvas-video-build t))))
      (should (equal (with-temp-buffer
                       (insert-file-contents "builds") (buffer-string))
                     "built\nbuilt\n")))))

(ert-deftest canvas-video-build-failure-keeps-diagnostics ()
  (skip-unless (executable-find "make"))
  (canvas-video-build-test--with-directory
    (with-temp-file "Makefile"
      (insert "all:\n\t@echo 'intentional build failure' >&2\n\t@exit 1\n"))
    (let ((buffer (canvas-video-build)))
      (should-not (= 0 (canvas-video-build-test--wait buffer)))
      (with-current-buffer buffer
        (should (derived-mode-p 'compilation-mode))
        (should (string-match-p "intentional build failure" (buffer-string)))))))

(ert-deftest canvas-video-build-missing-make ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil)))
    (should-error (canvas-video-build) :type 'user-error)))

(ert-deftest canvas-video-build-missing-sources-or-header ()
  (skip-unless (executable-find "make"))
  (canvas-video-build-test--with-directory
    (should-error (canvas-video-build) :type 'user-error)
    (with-temp-file "Makefile" (insert "all:\n\t@true\n"))
    (let ((canvas-video-emacs-include (expand-file-name "missing-headers")))
      (should-error (canvas-video-build) :type 'user-error))
    (should-not (get-buffer "*canvas-video-build*"))))

;;; canvas-video-build-test.el ends here
