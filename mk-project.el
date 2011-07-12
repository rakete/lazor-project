;;; mk-project.el ---  Lightweight project handling

;; Copyright (C) 2010  Matt Keller <mattkeller at gmail dot com>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Quickly switch between projects and perform operations on a
;; per-project basis. A 'project' in this sense is a directory of
;; related files, usually a directory of source files. Projects are
;; defined in pure elisp with the 'project-def' function. No
;; mk-project-specific files are required in the project's base
;; directory.

;; More information about this library, including the most recent
;; version and a comprehensive README, is available at
;; http://github.com/mattkeller/mk-project

;;; Code:

(require 'grep)
(require 'thingatpt)
(require 'cl)

(defvar mk-proj-version "1.4.0"
  "As tagged at http://github.com/mattkeller/mk-project/tree/master")

;; ---------------------------------------------------------------------
;; Project Variables
;;
;; These variables are set when a project is loaded and nil'd out when
;; unloaded. These symbols are the same as defined in the 2nd parameter
;; to project-def except for their "mk-proj-" prefix.
;; ---------------------------------------------------------------------

(defvar mk-proj-name nil
  "Name of the current project. Required. First argument to project-def.")

(defvar mk-proj-basedir nil
  "Base directory of the current project. Required. Value is expanded with
expand-file-name. Example: ~me/my-proj/.")

(defvar mk-proj-src-patterns nil
  "List of shell patterns to include in the TAGS file. Optional. Example:
'(\"*.java\" \"*.jsp\").

This value is not used when `mk-proj-src-find-cmd' is set.")

(defvar mk-proj-ignore-patterns nil
  "List of shell patterns to avoid searching for with project-find-file and
project-grep. Optional. Example: '(\"*.class\").

This value is not used in indexing when `mk-proj-index-find-cmd'
is set -- or in grepping when `mk-proj-grep-find-cmd' is set.")

(defvar mk-proj-ack-args nil
  "String of arguments to pass to the `ack' command. Optional.
Example: \"--java\".")

(defvar mk-proj-vcs nil
  "When set to one of the VCS types in `mk-proj-vcs-path', grep
and index commands will ignore the VCS's private files (e.g.,
.CVS/). Example: 'git.

This value is not used in indexing when `mk-proj-index-find-cmd'
is set -- or in grepping when `mk-proj-grep-find-cmd' is set.")

; TODO: support multiple tags file via tags-table-list
(defvar mk-proj-tags-file nil
  "Path to the TAGS file for this project. Optional. Use an absolute path,
not one relative to basedir. Value is expanded with expand-file-name.")

(defvar mk-proj-compile-cmd nil
  "Shell command to build the entire project. Optional. Example: make -k.")

(defvar mk-proj-startup-hook nil
  "Hook function to run after the project is loaded. Optional. Project
variables (e.g. mk-proj-basedir) will be set and can be referenced from this
function.")

(defvar mk-proj-shutdown-hook nil
  "Hook function to run after the project is unloaded. Optional.  Project
variables (e.g. mk-proj-basedir) will still be set and can be referenced
from this function.")

(defvar mk-proj-file-list-cache nil
  "Cache *file-index* buffer to this file. Optional. If set, the *file-index*
buffer will take its initial value from this file and updates to the buffer
via 'project-index' will save to this file. Value is expanded with
expand-file-name.")

(defvar mk-proj-open-files-cache nil
  "Cache the names of open project files in this file. Optional. If set,
project-load will open all files listed in this file and project-unload will
write all open project files to this file. Value is expanded with
expand-file-name.")

(defvar mk-proj-src-find-cmd nil
  "Specifies a custom \"find\" command to locate all files to be
included in the TAGS file (see `project-tags'). Optional. The
value is either a string or a function of one argument that
returns a string. The argument to the function will be the symbol
\"'src\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `mk-proj-src-patterns' and
`mk-proj-vcs' settings are ignored when finding files to include
in TAGS.")

(defvar mk-proj-grep-find-cmd nil
  "Specifies a custom \"find\" command to use as the default when
running `project-grep'. Optional. The value is either a string or
a function of one argument that returns a string. The argument to
the function will be the symbol \"'grep\". The string or returned
string MUST use find's \"-print0\" argument as the results of
this command are piped to \"xargs -0 ...\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `mk-proj-ignore-patterns' and
`mk-proj-vcs' settings will not be used in the grep command.

The custom find command should use \".\" (current directory) as
the path that find starts at -- this will allow the C-u argument
to `project-grep' to run the command from the current buffer's
directory.")

(defvar mk-proj-index-find-cmd nil
  "Specifies a custom \"find\" command to use when building an
listing of all files in the project (to be used by
`project-find-file'). Optional. The value is either a string or a
function of one argument that returns a string. The argument to
the function will be the symbol \"'index\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `mk-proj-ignore-patterns' and
`mk-proj-vcs' settings are not used when in the grep command.")

(defconst mk-proj-fib-name "*file-index*"
  "Buffer name of the file-list cache. This buffer contains a
list of all the files under the project's basedir (minus those
matching ignore-patterns) or, if index-find-cmd is set, the list
of files found by calling the custom find command.  The list is
used by `project-find-file' to quickly locate project files.")

(defconst mk-proj-vcs-path '((git . "'*/.git/*'")
                             (cvs . "'*/.CVS/*'")
                             (svn . "'*/.svn/*'")
                             (bzr . "'*/.bzr/*'")
                             (hg  . "'*/.hg/*'")
                             (darcs . "'*/_darcs/*'"))
  "When `mk-proj-vcs' is one of the VCS types listed here, ignore
the associated paths when greping or indexing the project. This
value is not used if a custom find command is set in
`mk-proj-grep-find-cmd' or `mk-proj-index-find-cmd'")

(defvar mk-proj-required-vars '(name
                                basedir)
  "Project config vars that are required in every project.

See also `mk-proj-optional-vars' `mk-proj-var-functions' `mk-proj-load-vars'")

(defvar mk-proj-optional-vars '(src-patterns
                                ignore-patterns
                                ack-args
                                vcs
                                tags-file
                                compile-cmd
                                startup-hook
                                shutdown-hook
                                file-list-cache
                                open-files-cache
                                src-find-cmd
                                grep-find-cmd
                                index-find-cmd
                                etags-cmd
                                patterns-are-regex)
  "Project config vars that are optional.

See also `mk-proj-required-vars' `mk-proj-var-functions' `mk-proj-load-vars'")

(defvar mk-proj-var-functions '((basedir . expand-file-name)
                                (tags-file . expand-file-name)
                                (file-list-cache . expand-file-name)
                                (open-files-cache . expand-file-name))
  "Config vars from `mk-proj-required-vars' and `mk-proj-optional-vars' (except 'name')
can be associated with a function in this association list, which will be
applied to the value of the var before loading the project.

See also `mk-proj-load-vars'.")

(defvar mk-proj-project-load-hook '())

(defvar mk-proj-project-unload-hook '())

;; ---------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------

(defgroup mk-project nil
  "A programming project management library."
  :group 'tools)

(defcustom mk-proj-ack-respect-case-fold t
  "If on and case-fold-search is true, project-ack will ignore case by passing \"-i\" to ack."
  :type 'boolean
  :group 'mk-project)

(defcustom mk-proj-use-ido-selection nil
  "If ido-mode is available, use ido selection where appropriate."
  :type 'boolean
  :group 'mk-project)

(defcustom mk-proj-ack-cmd (if (string-equal system-type "windows-nt") "ack.pl" "ack")
  "Name of the ack program to run. Defaults to \"ack\" (or \"ack.pl\" on Windows)."
  :type 'string
  :group 'mk-project)

(defcustom mk-proj-file-index-relative-paths t
  "If non-nil, generate relative path names in the file-index buffer"
  :type 'boolean
  :group 'mk-project)

;; ---------------------------------------------------------------------
;; Utils
;; ---------------------------------------------------------------------

(defun mk-proj-replace-tail (str tail-str replacement)
  (if (string-match (concat tail-str "$")  str)
    (replace-match replacement t t str)
    str))

(defun mk-proj-assert-proj ()
  (unless mk-proj-name
    (error "No project is set!")))

(defun mk-proj-maybe-kill-buffer (bufname)
  (let ((b (get-buffer bufname)))
    (when b (kill-buffer b))))

(defun mk-proj-get-vcs-path ()
  (if mk-proj-vcs
      (cdr (assoc mk-proj-vcs mk-proj-vcs-path))
    nil))

(defun mk-proj-has-univ-arg ()
  (eql (prefix-numeric-value current-prefix-arg) 4))

(defun mk-proj-names ()
  (let ((names nil))
    (maphash (lambda (k v) (add-to-list 'names k)) mk-proj-list)
    names))

(defun mk-proj-use-ido ()
  (and (boundp 'ido-mode) mk-proj-use-ido-selection))

(defun mk-proj-find-cmd-val (context)
  (let ((cmd (ecase context
               ('src   mk-proj-src-find-cmd)
               ('grep  mk-proj-grep-find-cmd)
               ('index mk-proj-index-find-cmd))))
    (if cmd
        (cond ((stringp cmd) cmd)
              ((functionp cmd) (funcall cmd context))
              (t (error "find-cmd is neither a string or a function")))
      nil)))

(defun mk-proj-filter (condp lst)
  (delq nil
        (mapcar (lambda (x) (and (funcall condp x) x)) lst)))

(defun* mk-proj-any (condp lst)
  (let (b)
    (dolist (x lst b)
      (when b
        (return-from "mk-proj-any" t))
      (setq b (funcall condp x)))))

(defun mk-proj-flatten (xs)
  (let ((ret nil))
    (while xs
      (setq ret (append ret (car xs)))
      (setq xs (cdr xs)))
    ret))

(defmacro mk-proj-assoc-pop (key alist)
  `(let ((result (assoc ,key ,alist)))
     (setq ,alist (delete result ,alist))
     result))

(defun mk-proj-alist-union (alist1 alist2)
  (append (mapcar (lambda (c)
                    (or (mk-proj-assoc-pop (car c) alist2) c)) alist1) alist2))

;; ---------------------------------------------------------------------
;; Project Configuration
;; ---------------------------------------------------------------------

(defvar mk-proj-list (make-hash-table :test 'equal))

(defun mk-proj-find-config (proj-name)
  (gethash proj-name mk-proj-list))

(defun mk-proj-config-val (proj-name key)
  (if (assoc key (mk-proj-find-config proj-name))
      (car (cdr (assoc key (mk-proj-find-config proj-name))))
    nil))

(defun project-def (proj-name config-alist &optional inherit)
  "Associate the settings in <config-alist> with project <proj-name>"
  (if inherit
      (let ((parent-alist (if (char-or-string-p inherit)
                              (gethash inherit mk-proj-list)
                            (gethash proj-name mk-proj-list))))
        (puthash proj-name (mk-proj-alist-union parent-alist config-alist) mk-proj-list))
    (puthash proj-name config-alist mk-proj-list)))

(defun mk-proj-proj-vars ()
  "This returns a list of all proj-vars as symbols.
Replaces the old mk-proj-proj-vars constant."
  (mapcar (lambda (var)
            (intern (concat "mk-proj-" (symbol-name var))))
          (append mk-proj-required-vars mk-proj-optional-vars)))

(defun mk-proj-defaults ()
  "Set all default values for project variables"
    (dolist (var (mk-proj-proj-vars))
      (set var nil)))

(defun mk-proj-load-vars (proj-name proj-alist &optional init)
  "Set project variables from proj-alist. A project variable is what
a config variable becomes after loading a project. Essentially
a global lisp symbol with the same name as the config variable
prefixed by 'mk-proj-'. For example, the basedir config var becomes
mk-proj-basedir in global scope.

If init is non-nil this function checks the proj-alist for required
config vars and throws the first missing symbol (if any) and exits.
Keep in mind that without the init argument, the required vars are
ignored completly.

See also `mk-proj-required-vars' `mk-proj-optional-vars' `mk-proj-var-functions'"
  (catch 'mk-proj-load-vars
    (labels ((config-val (key)
                         (if (assoc key proj-alist)
                             (car (cdr (assoc key proj-alist)))
                           nil))
             (maybe-set-var (var)
                            (let ((proj-var (intern (concat "mk-proj-" (symbol-name var))))
                                  (val (config-val var))
                                  (fn (cdr (assoc var mk-proj-var-functions))))
                              (when val
                                (setf (symbol-value proj-var) (if fn (funcall fn val) val))))))
      (mk-proj-defaults)
      (if init
          (let ((required-vars (mk-proj-filter (lambda (s)
                                                 (not (string-equal (symbol-name s) "name")))
                                               mk-proj-required-vars)))
            (setq mk-proj-name proj-name)
            (dolist (v required-vars)
              (unless (config-val v)
                (mk-proj-defaults)
                (throw 'mk-proj-load-vars v))
              (maybe-set-var v)))) 
      (dolist (v mk-proj-optional-vars)
        (maybe-set-var v)))))

(defun mk-proj-load (name)
  (interactive)
  (catch 'mk-proj-load
    (let ((oldname mk-proj-name))
      (unless (string= oldname name)
        (project-unload))
      (let ((proj-config (mk-proj-find-config name)))
        (if proj-config
            (let ((v (mk-proj-load-vars name proj-config t)))
              (when v
                (message "Required config value '%s' missing in %s!" (symbol-name v) name)
                (throw 'mk-proj-load t)))
          (message "Project %s does not exist!" name)
          (throw 'mk-proj-load t)))
      (when (not (file-directory-p mk-proj-basedir))
        (message "Base directory %s does not exist!" mk-proj-basedir)
        (throw 'mk-proj-load t))
      (when (and mk-proj-vcs (not (mk-proj-get-vcs-path)))
        (message "Invalid VCS setting!")
        (throw 'mk-proj-load t))
      (message "Loading project %s ..." name)
      (cd mk-proj-basedir)
      (mk-proj-tags-load)
      (mk-proj-fib-init)
      (add-hook 'kill-emacs-hook 'mk-proj-kill-emacs-hook)
      (when mk-proj-startup-hook
        (run-hooks 'mk-proj-startup-hook))
      (run-hooks 'mk-proj-project-load-hook)
      (mk-proj-visit-saved-open-files)
      (message "Loading project %s done" name))))
  

(defun project-load ()
  "Load a project's settings."
  (interactive)
  (let ((name (if (mk-proj-use-ido)
                  (ido-completing-read "Project Name (ido): " (mk-proj-names))
                (completing-read "Project Name: " (mk-proj-names)))))
    (mk-proj-load name)))

(defun mk-proj-kill-emacs-hook ()
  "Ensure we save the open-files-cache info on emacs exit"
  (when (and mk-proj-name mk-proj-open-files-cache)
    (mk-proj-save-open-file-info)))

(defun project-unload ()
  "Unload the current project's settings after running the shutdown hook."
  (interactive)
  (when mk-proj-name
    (condition-case nil
        (progn
          (message "Unloading project %s" mk-proj-name)
          (mk-proj-tags-clear)
          (mk-proj-maybe-kill-buffer mk-proj-fib-name)
          (mk-proj-save-open-file-info)
          (when (and (mk-proj-buffers)
                     (y-or-n-p (concat "Close all " mk-proj-name " project files? "))
                     (project-close-files)))
          (when mk-proj-shutdown-hook (run-hooks 'mk-proj-shutdown-hook))
          (run-hooks 'mk-proj-project-unload-hook))
      (error nil)))
  (mk-proj-defaults)
  (message "Project settings have been cleared"))

(defun project-close-files ()
  "Close all unmodified files that reside in the project's basedir"
  (interactive)
  (mk-proj-assert-proj)
  (let ((closed nil)
        (dirty nil)
        (basedir-len (length mk-proj-basedir)))
    (dolist (b (mk-proj-buffers))
      (cond
       ((or (buffer-modified-p b) (string-equal (buffer-name b) "*scratch*"))
        (push (buffer-name b) dirty))
       (t
        (push (buffer-name b) closed)
        (kill-buffer b))))
    (message "Closed %d buffers, %d modified buffers where left open"
             (length closed) (length dirty))))

(defun mk-proj-buffer-name (buf)
  "Return buffer's name based on filename or dired's location"
  (let ((file-name (or (buffer-file-name buf)
                       (with-current-buffer buf list-buffers-directory))))
    (if file-name
        (expand-file-name file-name)
      nil)))

(defun mk-proj-buffer-p (buf)
  "Is the given buffer in our project based on filename? Also detects dired buffers open to basedir/*"
  (let ((file-name (mk-proj-buffer-name buf)))
    (if (and file-name
             (string-match (concat "^" (regexp-quote mk-proj-basedir)) file-name))
        t
      nil)))

(defun mk-proj-buffers ()
  "Get a list of buffers that reside in this project's basedir"
  (let ((buffers nil))
    (dolist (b (buffer-list))
      (when (mk-proj-buffer-p b) (push b buffers)))
    buffers))

(defun project-status ()
  "View project's variables."
  (interactive)
  (if mk-proj-basedir
      (let ((msg))
        (dolist (v (mk-proj-proj-vars))
          (setq msg (concat msg (format "%-24s = %s\n" v (symbol-value v)))))
        (message msg))
    (message "No project loaded.")))

;; ---------------------------------------------------------------------
;; Save/Restore open files
;; ---------------------------------------------------------------------

(defun mk-proj-save-open-file-info ()
  "Write the list of `files' to a file"
  (when mk-proj-open-files-cache
    (with-temp-buffer
      (dolist (f (mapcar (lambda (b) (mk-proj-buffer-name b)) (mk-proj-buffers)))
        (when f
          (unless (string-equal mk-proj-tags-file f)
            (insert f "\n"))))
      (if (file-writable-p mk-proj-open-files-cache)
          (progn
            (write-region (point-min)
                          (point-max)
                          mk-proj-open-files-cache)
            (message "Wrote open files to %s" mk-proj-open-files-cache))
        (message "Cannot write to %s" mk-proj-open-files-cache)))))

(defun mk-proj-visit-saved-open-files ()
  (when mk-proj-open-files-cache
    (when (file-readable-p mk-proj-open-files-cache)
      (message "Reading open files from %s" mk-proj-open-files-cache)
      (with-temp-buffer
        (insert-file-contents mk-proj-open-files-cache)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((start (point)))
            (while (not (eolp)) (forward-char)) ; goto end of line
            (let ((line (buffer-substring start (point))))
              (message "Attempting to open %s" line)
              (find-file-noselect line t)))
          (forward-line))))))

;; ---------------------------------------------------------------------
;; Etags
;; ---------------------------------------------------------------------

(defun mk-proj-tags-load ()
  "Load TAGS file (if tags-file set)"
  (mk-proj-tags-clear)
  (setq tags-file-name  mk-proj-tags-file
        tags-table-list nil)
  (when (and mk-proj-tags-file (file-readable-p mk-proj-tags-file))
    (visit-tags-table mk-proj-tags-file)))

(defun mk-proj-tags-clear ()
  "Clear the TAGS file (if tags-file set)"
  (when (and mk-proj-tags-file (get-file-buffer mk-proj-tags-file))
    (mk-proj-maybe-kill-buffer (get-file-buffer mk-proj-tags-file)))
  (setq tags-file-name  nil
        tags-table-list nil))

(defun mk-proj-etags-cb (process event)
  "Visit tags table when the etags process finishes."
  (message "Etags process %s received event %s" process event)
  (kill-buffer (get-buffer "*etags*"))
  (cond
   ((string= event "finished\n")
    (mk-proj-tags-load)
    (message "Refreshing TAGS file %s...done" mk-proj-tags-file))
   (t (message "Refreshing TAGS file %s...failed" mk-proj-tags-file))))

(defun project-tags ()
  "Regenerate the project's TAG file. Runs in the background."
  (interactive)
  (mk-proj-assert-proj)
  (if mk-proj-tags-file
      (let* ((tags-file-name (file-name-nondirectory mk-proj-tags-file))
             ;; If the TAGS file is in the basedir, we can generate
             ;; relative filenames which will allow the TAGS file to
             ;; be relocatable if moved with the source. Otherwise,
             ;; run the command from the TAGS file's directory and
             ;; generate absolute filenames.
             (relative-tags (string= (file-name-as-directory mk-proj-basedir)
                                     (file-name-directory mk-proj-tags-file)))
             (default-directory (file-name-as-directory
                                 (file-name-directory mk-proj-tags-file)))
             (default-find-cmd (concat "find '" (if relative-tags "." mk-proj-basedir)
                                       "' -type f "
                                       (mk-proj-find-cmd-src-args mk-proj-src-patterns)))
             (etags-shell-cmd (if mk-proj-etags-cmd
                                  mk-proj-etags-cmd
                                "etags -o"))
             (etags-cmd (concat (or (mk-proj-find-cmd-val 'src) default-find-cmd)
                                " | " etags-shell-cmd " '" tags-file-name "' - "))
             (proc-name "etags-process"))
        (message "project-tags default-dir %s" default-directory)
        (message "project-tags cmd \"%s\"" etags-cmd)
        (message "Refreshing TAGS file %s..." mk-proj-tags-file)
        (start-process-shell-command proc-name "*etags*" etags-cmd)
        (set-process-sentinel (get-process proc-name) 'mk-proj-etags-cb))
    (message "mk-proj-tags-file is not set")))

(defun mk-proj-find-cmd-src-args (src-patterns)
  "Generate the ( -name <pat1> -o -name <pat2> ...) pattern for find cmd"
  (if src-patterns
      (let ((name-expr " \\(")
            (regex-or-name-arg (if mk-proj-patterns-are-regex
                                   "-regex"
                                 "-name")))
        (dolist (pat src-patterns)
          (setq name-expr (concat name-expr " " regex-or-name-arg " \"" pat "\" -o ")))
        (concat (mk-proj-replace-tail name-expr "-o " "") "\\) "))
    ""))

(defun mk-proj-find-cmd-ignore-args (ignore-patterns)
  "Generate the -not ( -name <pat1> -o -name <pat2> ...) pattern for find cmd"
  (if ignore-patterns
      (concat " -not " (mk-proj-find-cmd-src-args ignore-patterns))
    ""))

;; ---------------------------------------------------------------------
;; Grep
;; ---------------------------------------------------------------------

(defun project-grep ()
  "Run find-grep on the project's basedir, excluding files in mk-proj-ignore-patterns, tag files, etc.
With C-u prefix, start from the current directory."
  (interactive)
  (mk-proj-assert-proj)
  (let* ((wap (word-at-point))
         (regex (if wap (read-string (concat "Grep project for (default \"" wap "\"): ") nil nil wap)
                  (read-string "Grep project for: ")))
         (find-cmd "find . -type f")
         (grep-cmd (concat "grep -i -n \"" regex "\""))
         (default-directory (file-name-as-directory
                             (if (mk-proj-has-univ-arg)
                                 default-directory
                               mk-proj-basedir))))
    (when mk-proj-ignore-patterns
      (setq find-cmd (concat find-cmd (mk-proj-find-cmd-ignore-args mk-proj-ignore-patterns))))
    (when mk-proj-tags-file
      (setq find-cmd (concat find-cmd " -not -name 'TAGS'")))
    (when (mk-proj-get-vcs-path)
      (setq find-cmd (concat find-cmd " -not -path " (mk-proj-get-vcs-path))))
    (let* ((whole-cmd (concat (or (mk-proj-find-cmd-val 'grep)
                                  (concat find-cmd " -print0"))
                              " | xargs -0 -e " grep-cmd))
           (confirmed-cmd (read-string "Grep command: " whole-cmd nil whole-cmd)))
      (message "project-grep cmd: \"%s\"" confirmed-cmd)
      (grep-find confirmed-cmd))))

;; ---------------------------------------------------------------------
;; Ack (betterthangrep.com)
;; ---------------------------------------------------------------------

(define-compilation-mode ack-mode "Ack" "Ack compilation mode." nil)

(defvar mk-proj-ack-default-args "--nocolor --nogroup")

(defun mk-proj-ack-cmd (regex)
  "Generate the ack command string given a regex to search for."
  (concat mk-proj-ack-cmd " "
          mk-proj-ack-default-args " "
          (if (and mk-proj-ack-respect-case-fold case-fold-search) "-i " "")
          mk-proj-ack-args " "
          regex))

(defun project-ack ()
  "Run ack from project's basedir, using the `ack-args' configuration.
With C-u prefix, start ack from the current directory."
  (interactive)
  (mk-proj-assert-proj)
  (let* ((wap (word-at-point))
         (regex (if wap (read-string (concat "Ack project for (default \"" wap "\"): ") nil nil wap)
                  (read-string "Ack project for: ")))
         (whole-cmd (mk-proj-ack-cmd regex))
         (confirmed-cmd (read-string "Ack command: " whole-cmd nil whole-cmd))
         (default-directory (file-name-as-directory
                             (if (mk-proj-has-univ-arg)
                                 default-directory
                               mk-proj-basedir))))
    (compilation-start confirmed-cmd 'ack-mode)))

;; ---------------------------------------------------------------------
;; Compile
;; ---------------------------------------------------------------------

(defun mk-proj-compile (opts)
  "Please don't use this manually, it is supposed to be called by
`project-compile'."
  (interactive "sCompile options: ")
  (mk-proj-assert-proj)
  (project-home)
  (compile (concat mk-proj-compile-cmd " " opts)))

(defun project-compile (&optional opts)
  "Run the compile command for this project."
  (interactive)
  (mk-proj-assert-proj)
  (project-home)
  (if (stringp mk-proj-compile-cmd)
      (if opts
          (funcall 'mk-proj-compile opts)
        (call-interactively 'mk-proj-compile))
    (if (fboundp mk-proj-compile-cmd)
        (if (commandp mk-proj-compile-cmd)
            (call-interactively mk-proj-compile-cmd)
          (funcall mk-proj-compile-cmd)))))

;; ---------------------------------------------------------------------
;; Home and Dired
;; ---------------------------------------------------------------------

(defun project-home ()
  "cd to the basedir of the current project"
  (interactive)
  (mk-proj-assert-proj)
  (cd mk-proj-basedir))

(defun project-dired ()
  "Open dired in the project's basedir (or jump to the existing dired buffer)"
  (interactive)
  (mk-proj-assert-proj)
  (dired mk-proj-basedir))

;; ---------------------------------------------------------------------
;; Find-file
;; ---------------------------------------------------------------------

(defun mk-proj-fib-init ()
  "Either load the *file-index* buffer from the file cache, or create it afresh."
  (if (and mk-proj-file-list-cache
           (file-readable-p mk-proj-file-list-cache))
      (with-current-buffer (find-file-noselect mk-proj-file-list-cache)
          (with-current-buffer (rename-buffer mk-proj-fib-name)
            (setq buffer-read-only t)
            (set-buffer-modified-p nil)
            (message "Loading *file-index* from %s" mk-proj-file-list-cache)))
    (project-index)))

(defun mk-proj-fib-clear ()
  "Clear the contents of the fib buffer"
  (let ((buf (get-buffer mk-proj-fib-name)))
    (when buf
      (with-current-buffer buf
        (setq buffer-read-only nil)
        (kill-region (point-min) (point-max))
        (setq buffer-read-only t)))))

(defun mk-proj-fib-cb (process event)
  "Handle failure to complete fib building"
  (cond
   ((string= event "finished\n")
    (with-current-buffer (get-buffer mk-proj-fib-name)
      (setq buffer-read-only t)
      (when mk-proj-file-list-cache
        (write-file mk-proj-file-list-cache)
        (rename-buffer mk-proj-fib-name)))
    (message "Refreshing %s buffer...done" mk-proj-fib-name))
   (t
    (mk-proj-fib-clear)
    (message "Failed to generate the %s buffer!" mk-proj-fib-name))))

(defun project-index ()
  "Regenerate the *file-index* buffer that is used for project-find-file"
  (interactive)
  (mk-proj-assert-proj)
  (when mk-proj-file-list-cache
    (mk-proj-fib-clear)
    (let* ((default-directory (file-name-as-directory mk-proj-basedir))
           (start-dir (if mk-proj-file-index-relative-paths "." mk-proj-basedir))
           (find-cmd (concat "find '" start-dir "' -type f "
                             (mk-proj-find-cmd-src-args mk-proj-src-patterns)
                             (mk-proj-find-cmd-ignore-args mk-proj-ignore-patterns)))
           (proc-name "index-process"))
      (when (mk-proj-get-vcs-path)
        (setq find-cmd (concat find-cmd " -not -path " (mk-proj-get-vcs-path))))
      (setq find-cmd (or (mk-proj-find-cmd-val 'index) find-cmd))
      (with-current-buffer (get-buffer-create mk-proj-fib-name)
        (buffer-disable-undo) ;; this is a large change we don't need to undo
        (setq buffer-read-only nil))
      (message "project-index cmd: \"%s\"" find-cmd)
      (message "Refreshing %s buffer..." mk-proj-fib-name)
      (start-process-shell-command proc-name mk-proj-fib-name find-cmd)
      (set-process-sentinel (get-process proc-name) 'mk-proj-fib-cb))))

(defun mk-proj-fib-matches (regex)
  "Return list of files in *file-index* matching regex. 

If regex is nil, return all files. Returned file paths are
relative to the project's basedir."
  (let ((files '()))
    (with-current-buffer mk-proj-fib-name
      (goto-char (point-min))
      (while 
          (progn
            (let ((raw-file (buffer-substring (line-beginning-position) (line-end-position))))
              (when (> (length raw-file) 0)
                ;; file names in buffer can be absolute or relative to basedir
                (let ((file (if (file-name-absolute-p raw-file) 
                                (file-relative-name raw-file mk-proj-basedir)
                              raw-file)))
                  (if regex
                      (when (string-match regex file) (add-to-list 'files file))
                    (add-to-list 'files file)))
                (= (forward-line) 0))))) ; loop test
      (sort files #'string-lessp))))

(defun* project-find-file (regex)
  "Find file in the current project matching the given regex.

The files listed in buffer *file-index* are scanned for regex
matches. If only one match is found, the file is opened
automatically. If more than one match is found, prompt for
completion. See also: `project-index', `project-find-file-ido'."
  (interactive "sFind file in project matching: ")
  (mk-proj-assert-proj)
  (unless (get-buffer mk-proj-fib-name)
    (message "Please use project-index to create the index before running project-find-file")
    (return-from "project-find-file" nil))
    (let* ((matches (mk-proj-fib-matches regex))
           (match-cnt (length matches)))
      (cond
       ((= 0 match-cnt)
        (message "No matches for \"%s\" in this project" regex))
       ((= 1 match-cnt )
        (find-file (car matches)))
       (t
        (let ((file (if (mk-proj-use-ido)
                        (ido-completing-read "Multiple matches, pick one (ido): " matches)
                      (completing-read "Multiple matches, pick one: " matches))))
          (when file
            (find-file (concat (file-name-as-directory mk-proj-basedir) file))))))))

(defun* project-find-file-ido ()
  "Find file in the current project using 'ido'.

Choose a file to open from among the files listed in buffer
*file-index*.  The ordinary 'ido' methods allow advanced
selection of the file. See also: `project-index',
`project-find-file'."
  (interactive)
  (mk-proj-assert-proj)
  (unless (get-buffer mk-proj-fib-name)
    (message "Please use project-index to create the index before running project-find-file-ido")
    (return-from "project-find-file-ido" nil))
  (let ((file (ido-completing-read "Find file in project matching (ido): "
                                   (mk-proj-fib-matches nil))))
    (when file
      (find-file (concat (file-name-as-directory mk-proj-basedir) file)))))

(defun project-multi-occur (regex)
  "Search all open project files for 'regex' using `multi-occur'"
  (interactive "sRegex: ")
  (multi-occur (mk-proj-filter (lambda (b) (if (buffer-file-name b) b nil)) 
                               (mk-proj-buffers))
               regex))

(defun* project-next-buffer ()
  "Switch to the next project buffer in cyclic order."
  (interactive)
  (mk-proj-assert-proj)
  (unless (mk-proj-buffers)
      (return-from "project-next-buffer" nil))
  (let ((counter 0)
        (proj-buffers (mapcar 'buffer-name (mk-proj-buffers))))
    (next-buffer)
    (while (not (or (mk-proj-any (lambda (x) (string-equal (buffer-name) x)) proj-buffers)
                    (> counter 1000)))
      (setq counter (+ counter 1))
      (next-buffer))))

(defun* project-previous-buffer ()
  "Switch to the previous project buffer in cyclic order."
  (interactive)
  (mk-proj-assert-proj)
  (unless (mk-proj-buffers)
      (return-from "project-previous-buffer" nil))
  (let ((counter 0)
        (proj-buffers (mapcar 'buffer-name (mk-proj-buffers))))
    (previous-buffer)
    (while (not (or (mk-proj-any (lambda (x) (string-equal (buffer-name) x)) proj-buffers)
                    (> counter 1000)))
      (setq counter (+ counter 1))
      (previous-buffer))))

(provide 'mk-project)

;;; mk-project.el ends here
