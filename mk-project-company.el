(require 'mk-project)
(require 'company)
(require 'cl-lib)

(defgroup company-project nil
  "Completion back-end for Mk Project."
  :group 'company)

(defvar mk-company-complete-in-projects t)

(defvar mk-company-project-name nil)

(defun mk-company-gtags (prefix)
  (let* ((cmd (concat "global --match-part=first -Gq -c \"\""))
         (completions (split-string (condition-case nil (shell-command-to-string cmd) (error nil)) "\n" t)))
    (when completions
      (loop for completion in completions
            if (string-match (concat "^" prefix) completion)
            collect completion))))

(defun mk-company-imenu (prefix)
  (let* ((imenu-alist (condition-case nil
                          (if (functionp 'imenu--make-many-index-alist)
                              (imenu--make-many-index-alist)
                            (imenu--make-index-alist))
                        (error nil)))
         (marker-list (append (cdr (assoc "Types" imenu-alist))
                              (cdr (assoc "Variables" imenu-alist))
                              (nthcdr 3 imenu-alist))))
    (loop for tuple in marker-list
          if (string-match (concat "^" prefix) (car tuple))
          collect (car tuple))))

(defun mk-company-obarray (prefix)
  (let (results)
    (do-all-symbols (sym results)
      (when (or (fboundp sym)
                (boundp sym))
        (let* ((completion (symbol-name sym)))
          (when (string-match (concat "^" prefix) completion)
            (push completion results)))))))

;;;###autoload
(defun company-project-runtime (command &optional arg &rest ignored)
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'company-project))
    (no-cache nil)
    (sorted nil)
    (duplicates nil)
    (prefix (and (not (company-in-string-or-comment))
                 (buffer-file-name (current-buffer))
                 (or mk-proj-name
                     mk-company-project-name)
                 (or (eq mk-company-complete-in-projects t)
                     (find (or mk-proj-name
                               mk-company-project-name) mk-company-complete-in-projects))
                 (company-grab-symbol)))
    (candidates (append (mk-company-gtags arg)
                        (mk-company-imenu arg)
                        (mk-company-obarray arg)))
    (meta (let* ((cache (gethash arg mk-proj-definitions-cache))
                 (definition (plist-get cache :definition))
                 (docstring (plist-get cache :docstring))
                 (meta nil))
            (when docstring
              (push docstring meta))
            (when definition
              (push definition meta))
            (when meta
              (mapconcat 'identity meta ": "))))
    ;;(location (mk-company-get-jump arg 'location))
    (init (setq-local mk-company-project-name (or mk-company-project-name (cadr (assoc 'name (mk-proj-guess-alist))))))))

;;;###autoload
(defun company-project-cached (command &optional arg &rest ignored)
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'company-project))
    (no-cache nil)
    (sorted nil)
    (duplicates t)
    (prefix (and (not (company-in-string-or-comment))
                 (buffer-file-name (current-buffer))
                 (or mk-company-project-name
                     mk-proj-name)
                 (or (eq mk-company-complete-in-projects t)
                     (find (or mk-proj-name
                               mk-company-project-name) mk-company-complete-in-projects))
                 (company-grab-symbol)))
    (candidates (mk-proj-completions arg (or mk-proj-name
                                             mk-company-project-name)))
    (meta (let* ((cache (gethash arg mk-proj-definitions-cache))
                 (definition (plist-get cache :definition))
                 (docstring (plist-get cache :docstring))
                 (meta nil))
            (when docstring
              (push docstring meta))
            (when definition
              (push definition meta))
            (when meta
              (mapconcat 'identity meta ": "))))
    ;;(location (mk-company-get-jump arg 'location))
    (init (setq-local mk-company-project-name (or mk-company-project-name (cadr (assoc 'name (mk-proj-guess-alist))))))))

(provide 'mk-project-company)

;; mk-project-company.el ends here
