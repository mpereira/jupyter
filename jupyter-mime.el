;;; jupyter-mime.el --- Insert mime types -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 09 Nov 2018
;; Version: 0.7.3

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Routines for working with MIME types.
;; Also adds the following methods which may be extended:
;;
;; - jupyter-markdown-follow-link
;; - jupyter-insert
;;
;; For working with display IDs, currently rudimentary
;;
;; - jupyter-current-display
;; - jupyter-beginning-of-display
;; - jupyter-end-of-display
;; - jupyter-next-display-with-id
;; - jupyter-delete-current-display
;; - jupyter-update-display

;;; Code:

(require 'jupyter-base)
(require 'shr)
(require 'ansi-color)

(declare-function jupyter-message-content "jupyter-messages" (msg))
(declare-function org-format-latex "org" (prefix &optional beg end dir overlays msg forbuffer processing-type))
(declare-function markdown-link-at-pos "ext:markdown-mode" (pos))
(declare-function markdown-follow-link-at-point "ext:markdown-mode")

(defvar-local jupyter-display-ids nil
  "A hash table of display IDs.
Display IDs are implemented by setting the text property,
`jupyter-display', to the display ID requested by a
`:display-data' message. When a display is updated from an
`:update-display-data' message, the display ID from the initial
`:display-data' message is retrieved from this table and used to
find the display in the REPL buffer. See
`jupyter-update-display'.")

;;; Macros

;; Taken from `eshell-handle-control-codes'
(defun jupyter-handle-control-codes (beg end)
  "Handle any control sequences between BEG and END."
  (save-excursion
    (goto-char beg)
    (while (< (point) end)
      (let ((char (char-after)))
        (cond
         ((eq char ?\r)
          (if (< (1+ (point)) end)
              (if (memq (char-after (1+ (point)))
                        '(?\n ?\r))
                  (delete-char 1)
                (let ((end (1+ (point))))
                  (beginning-of-line)
                  (delete-region (point) end)))
            (add-text-properties (point) (1+ (point))
                                 '(invisible t))
            (forward-char)))
         ((eq char ?\a)
          (delete-char 1)
          (beep))
         ((eq char ?\C-h)
          (delete-region (1- (point)) (1+ (point))))
         (t
          (forward-char)))))))

(defmacro jupyter-with-control-code-handling (&rest body)
  "Handle control codes in any produced output generated by evaluating BODY.
After BODY is evaluated, call `jupyter-handle-control-codes'
on the region inserted by BODY."
  `(jupyter-with-insertion-bounds
       beg end (progn ,@body)
     ;; Handle continuation from previous messages
     (when (eq (char-before beg) ?\r)
       (move-marker beg (1- beg)))
     (jupyter-handle-control-codes beg end)))

;;; Fontificiation routines

(defun jupyter-fontify-buffer-name (mode)
  "Return the buffer name for fontifying MODE."
  (format " *jupyter-fontify[%s]*" mode))

(defun jupyter-fontify-buffer (mode)
  "Return the buffer used to fontify text for MODE.
Retrieve the buffer for MODE from `jupyter-fontify-buffers'.
If no buffer for MODE exists, create a new one."
  (let ((buf (get-buffer-create (jupyter-fontify-buffer-name mode))))
    (with-current-buffer buf
      (unless (eq major-mode mode)
        (delay-mode-hooks (funcall mode))))
    buf))

(defun jupyter-fixup-font-lock-properties (beg end &optional object)
  "Fixup the text properties in the `current-buffer' between BEG END.
If OBJECT is non-nil, fixup the text properties of OBJECT. Fixing
the text properties involves substituting any `face' property
with `font-lock-face'."
  (let ((next beg) val)
    (while (/= beg end)
      (setq val (get-text-property beg 'face object)
            next (next-single-property-change beg 'face object end))
      (remove-text-properties beg next '(face) object)
      (put-text-property beg next 'font-lock-face (or val 'default) object)
      (setq beg next))))

(defun jupyter-add-font-lock-properties (start end &optional object use-face)
  "Add font lock text properties between START and END in the `current-buffer'.
START, END, and OBJECT have the same meaning as in
`add-text-properties'. The properties added are the ones that
mark the text between START and END as fontified according to
font lock. Any text between START and END that does not have a
font-lock-face property will have the default face filled in for
the property and the face text property is swapped for
font-lock-face.

If USE-FACE is non-nil, do not replace the face text property
with font-lock-face."
  (unless use-face
    (jupyter-fixup-font-lock-properties start end object))
  (add-text-properties start end '(fontified t font-lock-fontified t) object))

(defun jupyter-fontify-according-to-mode (mode str &optional use-face)
  "Fontify a string according to MODE.
Return the fontified string. In addition to fontifying STR, if
MODE has a non-default `fill-forward-paragraph-function', STR
will be filled using `fill-region'.

If USE-FACE is non-nil, do not replace the face text property
with font-lock-face in the returned string."
  (with-current-buffer (jupyter-fontify-buffer mode)
    (erase-buffer)
    (insert str)
    (font-lock-ensure)
    (jupyter-add-font-lock-properties (point-min) (point-max) nil use-face)
    (when (not (memq fill-forward-paragraph-function
                     '(forward-paragraph)))
      (fill-region (point-min) (point-max) t 'nosqueeze))
    (buffer-string)))

(defun jupyter-fontify-region-according-to-mode (mode beg end)
  "Fontify a region according to MODE.
Fontify the region between BEG and END in the current buffer
according to MODE. This works by creating a new indirect buffer,
enabling MODE in the new buffer, ensuring the region is font
locked, adding required text properties, and finally re-enabling
the `major-mode' that was current before the call to this
function."
  (let ((restore-mode major-mode))
    (with-current-buffer
        (make-indirect-buffer
         (current-buffer) (generate-new-buffer-name
                           (jupyter-fontify-buffer-name mode)))
      (unwind-protect
          (save-restriction
            (narrow-to-region beg end)
            (delay-mode-hooks (funcall mode))
            (font-lock-ensure)
            (jupyter-fixup-font-lock-properties beg end))
        (kill-buffer)))
    (funcall restore-mode)))

;;; `jupyter-insert' method

(cl-defgeneric jupyter-insert (_mime _data &optional _metadata)
  "Insert MIME data in the current buffer.
Additions to this method should insert DATA assuming it has a
mime type of MIME. If METADATA is non-nil, it will be a property
list containing extra properties for inserting DATA such as
:width and :height for image mime types.

If MIME is considered handled, but does not insert anything in
the current buffer, return a non-nil value to indicate that MIME
has been handled."
  (ignore))

(cl-defmethod jupyter-insert ((plist cons) &optional metadata)
  "Insert the content contained in PLIST.
PLIST should be a property list that contains the key :data and
optionally the key :metadata. The value of :data shall be another
property list that contains MIME types as keys and their
representations as values. Alternatively, PLIST can be a full
message property list or be a property list that itself contains
mimetypes.

For each MIME type in `jupyter-mime-types' call

    (jupyter-insert MIME (plist-get data MIME) (plist-get metadata MIME))

until one of the invocations inserts text into the current
buffer (tested by comparisons with `buffer-modified-tick') or
returns a non-nil value. When either of these cases occur, return
MIME.

Note on non-graphic displays, `jupyter-nongraphic-mime-types' is
used instead of `jupyter-mime-types'.

When no valid mimetype is present, a warning is shown and nil is
returned."
  (cl-assert plist json-plist)
  (cl-destructuring-bind (data metadata)
      (jupyter-normalize-data plist metadata)
    (or (let ((tick (buffer-modified-tick)))
          (jupyter-loop-over-mime (if (display-graphic-p) jupyter-mime-types
                                    jupyter-nongraphic-mime-types)
              mime data metadata
            (and (or (jupyter-insert mime data metadata)
                     (/= tick (buffer-modified-tick)))
                 mime)))
        (prog1 nil
          (warn "No valid mimetype found %s"
                (cl-loop for (k _v) on data by #'cddr collect k))))))

;;; HTML

(defun jupyter--shr-put-image (spec alt &optional flags)
  "Identical to `shr-put-image', but ensure :ascent is 50.
SPEC, ALT and FLAGS have the same meaning as in `shr-put-image'.
The :ascent of an image is set to 50 so that the image center
aligns on the current line."
  (let ((image (shr-put-image spec alt flags)))
    (prog1 image
      (when image
        ;; Ensure we use an ascent of 50 so that the image center aligns with
        ;; the output prompt of a REPL buffer.
        (setf (image-property image :ascent) 50)
        (force-window-update)))))

(defun jupyter--delete-script-tags (beg end)
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char beg)
      (while (re-search-forward "<script[^>]*>" nil t)
        (delete-region
         (match-beginning 0)
         (if (re-search-forward "</script>" nil t)
             (point)
           (point-max)))))))

(defun jupyter-insert-html (html)
  "Parse and insert the HTML string using `shr'."
  (jupyter-with-insertion-bounds
      beg end (insert html)
    ;; TODO: We can't really do much about javascript so
    ;; delete those regions instead of trying to parse
    ;; them. Maybe just re-direct to a browser like with
    ;; widgets?
    ;; NOTE: Parsing takes a very long time when the text
    ;; is > ~500000 characters.
    (jupyter--delete-script-tags beg end)
    (let ((shr-put-image-function #'jupyter--shr-put-image)
          ;; Avoid issues with proportional fonts. Sometimes not all of the
          ;; text is rendered using proportional fonts. See #52.
          (shr-use-fonts nil))
      (if (save-excursion
            (goto-char beg)
            (looking-at "<\\?xml"))
          ;; Be strict about syntax when the html returned explicitly asks to
          ;; be parsed as xml. `libxml-parse-html-region' converts camel cased
          ;; tags/attributes such as viewBox to viewbox in the dom since html
          ;; is case insensitive. See #4.
          (cl-letf (((symbol-function #'libxml-parse-html-region)
                     #'libxml-parse-xml-region))
            (shr-render-region beg end))
        (shr-render-region beg end)))
    (jupyter-add-font-lock-properties beg end)))

;;; Markdown

(defvar markdown-hide-markup)
(defvar markdown-enable-math)
(defvar markdown-hide-urls)
(defvar markdown-fontify-code-blocks-natively)
(defvar markdown-mode-mouse-map)

(defvar jupyter-markdown-mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [return] 'jupyter-markdown-follow-link-at-point)
    (define-key map [follow-link] 'mouse-face)
    (define-key map [mouse-2] 'jupyter-markdown-follow-link-at-point)
    map)
  "Keymap when `point' is over a markdown link in the REPL buffer.")

(cl-defgeneric jupyter-markdown-follow-link (_link-text _url _ref-label _title-text _bang)
  "Follow the markdown link at `point'."
  (markdown-follow-link-at-point))

(defun jupyter-markdown-follow-link-at-point ()
  "Handle markdown links specially."
  (interactive)
  (let ((link (markdown-link-at-pos (point))))
    (when (car link)
      (apply #'jupyter-markdown-follow-link (cddr link)))))

(defun jupyter-insert-markdown (text)
  "Insert TEXT, fontifying it using `markdown-mode' first."
  (let ((beg (point)))
    (insert
     (let ((markdown-hide-markup t)
           (markdown-hide-urls t)
           (markdown-enable-math t)
           (markdown-fontify-code-blocks-natively t))
       (jupyter-fontify-according-to-mode 'markdown-mode text)))
    ;; Update keymaps
    (let ((end (point)) next)
      (setq beg (next-single-property-change beg 'keymap nil end))
      (while (/= beg end)
        (setq next (next-single-property-change beg 'keymap nil end))
        (when (eq (get-text-property beg 'keymap) markdown-mode-mouse-map)
          (put-text-property beg next 'keymap jupyter-markdown-mouse-map))
        (setq beg next)))))

;;; LaTeX

(defvar org-format-latex-options)
(defvar org-preview-latex-image-directory)
(defvar org-babel-jupyter-resource-directory)
(defvar org-preview-latex-default-process)

(defun jupyter-insert-latex (tex)
  "Generate and insert a LaTeX image based on TEX.

Note that this uses `org-format-latex' to generate the LaTeX
image."
  ;; FIXME: Getting a weird error when killing the temp buffers created by
  ;; `org-format-latex'. When generating the image, it seems that the temp
  ;; buffers created have the same major mode and local variables as the REPL
  ;; buffer which causes the query function to ask to kill the kernel client
  ;; when the temp buffers are killed!
  (let ((kill-buffer-query-functions nil)
        (org-format-latex-options
         `(:foreground
           default
           :background default :scale 2.0
           :matchers ,(plist-get org-format-latex-options :matchers))))
    (jupyter-with-insertion-bounds
        beg end (insert tex)
      ;; FIXME: Best way to cleanup these files? Just delete them by reading
      ;; the image data and using that for the image instead?
      (org-format-latex
       "ltximg" beg end org-babel-jupyter-resource-directory
       'overlays nil 'forbuffer
       ;; Use the default method for creating image files
       org-preview-latex-default-process)
      (dolist (o (overlays-in beg end))
        (when (eq (overlay-get o 'org-overlay-type)
                  'org-latex-overlay)
          (overlay-put o 'modification-hooks nil)))
      (overlay-recenter end)
      (goto-char end))))

;;; Images

(defun jupyter-insert-image (data type &optional metadata)
  "Insert image DATA as TYPE in the current buffer.
TYPE has the same meaning as in `create-image'. METADATA is a
plist containing :width and :height keys that will be used as the
width and height of the image."
  (cl-destructuring-bind (&key width height needs_background &allow-other-keys)
      metadata
    (let ((img (create-image
                data type 'data :width width :height height
                :mask (when needs_background
                        '(heuristic t)))))
      (insert-image img))))

;;; Plain text

(defun jupyter-insert-ansi-coded-text (text)
  "Insert TEXT, converting ANSI color codes to font lock faces."
  (jupyter-with-insertion-bounds
      beg end (insert (ansi-color-apply text))
    (jupyter-fixup-font-lock-properties beg end)))

;;; `jupyter-insert' method additions

(cl-defmethod jupyter-insert ((_mime (eql :text/html)) data
                              &context ((functionp 'libxml-parse-html-region)
                                        (eql t))
                              &optional _metadata)
  (jupyter-insert-html data)
  (insert "\n"))

(cl-defmethod jupyter-insert ((_mime (eql :text/markdown)) data
                              &context ((require 'markdown-mode nil t)
                                        (eql markdown-mode))
                              &optional _metadata)
  (jupyter-insert-markdown data))

(cl-defmethod jupyter-insert ((_mime (eql :text/latex)) data
                              &context ((require 'org nil t)
                                        (eql org))
                              &optional _metadata)
  (jupyter-insert-latex data)
  (insert "\n"))

(cl-defmethod jupyter-insert ((_mime (eql :image/svg+xml)) data
                              &context ((and (image-type-available-p 'svg) t)
                                        (eql t))
                              &optional metadata)
  (jupyter-insert-image data 'svg metadata)
  (insert "\n"))

(cl-defmethod jupyter-insert ((_mime (eql :image/jpeg)) data
                              &context ((and (image-type-available-p 'jpeg) t)
                                        (eql t))
                              &optional metadata)
  (jupyter-insert-image (base64-decode-string data) 'jpeg metadata)
  (insert "\n"))

(cl-defmethod jupyter-insert ((_mime (eql :image/png)) data
                              &context ((and (image-type-available-p 'png) t)
                                        (eql t))
                              &optional metadata)
  (jupyter-insert-image (base64-decode-string data) 'png metadata)
  (insert "\n"))

(cl-defmethod jupyter-insert ((_mime (eql :text/plain)) data
                              &optional _metadata)
  (jupyter-insert-ansi-coded-text data)
  (insert "\n"))

;;; Insert with display IDs

(cl-defmethod jupyter-insert :before ((_display-id string) &rest _)
  "Initialize `juptyer-display-ids'"
  ;; FIXME: Set the local display ID hash table for the current buffer, or
  ;; should display IDs be global? Then we would have to associate marker
  ;; positions as well in this table.
  (unless jupyter-display-ids
    (setq jupyter-display-ids (make-hash-table
                               :test #'equal
                               :weakness 'value))))

(cl-defmethod jupyter-insert ((display-id string) data &optional metadata)
  "Associate DISPLAY-ID with DATA when inserting DATA.
DATA and METADATA have the same meaning as in
`jupyter-insert'.

The default implementation adds a jupyter-display text property
to any inserted text and a jupyter-display-begin property to the
first character.

Currently there is no support for associating a DISPLAY-ID if
DATA is displayed as a widget."
  (jupyter-with-insertion-bounds
      beg end (jupyter-insert data metadata)
    ;; Don't add display IDs to widgets since those are currently implemented
    ;; using an external browser and not in the current buffer.
    (when (and (not (memq :application/vnd.jupyter.widget-view+json data))
               (< beg end))
      (let ((id (gethash display-id jupyter-display-ids)))
        (unless id
          (setq id (puthash display-id display-id jupyter-display-ids)))
        (put-text-property beg end 'jupyter-display id)
        (put-text-property beg (1+ beg) 'jupyter-display-begin t)))))

(cl-defgeneric jupyter-current-display ()
  "Return the display ID for the display at `point'.

The default implementation returns the jupyter-display text
property at `point'."
  (get-text-property (point) 'jupyter-display))

(cl-defgeneric jupyter-beginning-of-display ()
  "Go to the beginning of the current Jupyter display.

The default implementation moves `point' to the position of the
character with a jupyter-display-begin property. If `point' is
already at a character with such a property, then `point' is
returned."
  (if (get-text-property (point) 'jupyter-display-begin) (point)
    (goto-char
     (previous-single-property-change
      (point) 'jupyter-display-begin nil (point-min)))))

(cl-defgeneric jupyter-end-of-display ()
  "Go to the end of the current Jupyter display."
  (goto-char
   (min (next-single-property-change
         (point) 'jupyter-display nil (point-max))
        (next-single-property-change
         (min (1+ (point)) (point-max))
         'jupyter-display-begin nil (point-max)))))

(cl-defgeneric jupyter-next-display-with-id (id)
  "Go to the start of the next display matching ID.
Return non-nil if successful. If no display with ID is found,
return nil without moving `point'.

The default implementation searches the current buffer for text
with a jupyter-display text property matching ID."
  (or (and (bobp) (eq id (get-text-property (point) 'jupyter-display)))
      (let ((pos (next-single-property-change (point) 'jupyter-display-begin)))
        (while (and pos (not (eq (get-text-property pos 'jupyter-display) id)))
          (setq pos (next-single-property-change pos 'jupyter-display-begin)))
        (and pos (goto-char pos)))))

(cl-defgeneric jupyter-delete-current-display ()
  "Delete the current Jupyter display.

The default implementation checks if `point' has a non-nil
jupyter-display text property, if so, it deletes the surrounding
region around `point' containing that same jupyter-display
property."
  (when (jupyter-current-display)
    (delete-region
     (save-excursion (jupyter-beginning-of-display) (point))
     (save-excursion (jupyter-end-of-display) (point)))))

(cl-defgeneric jupyter-update-display ((display-id string) data &optional metadata)
  "Update the display with DISPLAY-ID using DATA.
DATA and METADATA have the same meaning as in a `:display-data'
message."
  (let ((id (and jupyter-display-ids
                 (gethash display-id jupyter-display-ids))))
    (unless id
      (error "Display ID not found (%s)" display-id))
    (save-excursion
      (goto-char (point-min))
      (let (bounds)
        (while (jupyter-next-display-with-id id)
          (jupyter-delete-current-display)
          (jupyter-with-insertion-bounds
              beg end (if bounds (insert-buffer-substring
                                  (current-buffer) (car bounds) (cdr bounds))
                        (jupyter-insert id data metadata))
            (unless bounds
              (setq bounds (cons (copy-marker beg) (copy-marker end))))
            (pulse-momentary-highlight-region beg end 'secondary-selection)))
        (when bounds
          (set-marker (car bounds) nil)
          (set-marker (cdr bounds) nil)))
      (when (= (point) (point-min))
        (error "No display matching id (%s)" id)))))

(provide 'jupyter-mime)

;;; jupyter-mime.el ends here
