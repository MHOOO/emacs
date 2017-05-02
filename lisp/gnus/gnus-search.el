;;; gnus-search.el --- Search facilities for Gnus    -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Free Software Foundation, Inc.

;; Author: Eric Abrahamsen <eric@ericabrahamsen.net>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file defines a generalized search query language, and search
;; engines that interface with various search programs.  It is
;; responsible for parsing the user's input, querying the search
;; engines, and collecting results.  It relies on the nnselect backend
;; to create summary buffers displaying those results.

;; This file was formerly known as nnir.  Later, nnir became nnselect,
;; and only the search functionality was left here.

;; See the Gnus manual for details of the search language.  Tests are
;; in tests/gnus-search-test.el.

;; The search parsing routines are responsible for accepting the
;; user's search query as a string and parsing it into a sexp
;; structure.  The function `gnus-search-parse-query' is the entry
;; point for that.  Once the query is in sexp form, it is passed to
;; the search engines themselves, which are responsible for
;; transforming the query into a form that the external program can
;; understand, and then filtering the search results into a format
;; that nnselect can understand.

;; The general flow is:

;; 1. The user calls one of `gnus-group-make-search-group',
;; `gnus-group-make-permanent-search-group', or
;; `gnus-group-make-preset-search-group'.  These functions prompt for
;; a search query, then create an nnselect group where the function is
;; `gnus-search-run-query', and the args are the unparsed search
;; query, and the groups to search.

;; 2. `gnus-search-run-query' looks at the groups to search,
;; categorizes them by server, and for each server finds the search
;; engine to use.  Each engine is then called using the generic method
;; `gnus-search-run-search', with the query and groups passed as
;; arguments, and the results collected and handed off to the nnselect
;; group.

;; For information on writing new search engines, see the Gnus manual.

;;; Code:

(require 'gnus-group)
(require 'gnus-sum)
(require 'nnselect)
(require 'message)
(require 'gnus-util)
(require 'eieio)
(eval-when-compile (require 'cl-lib))
(autoload 'eieio-build-class-alist "eieio-opt")

(defvar gnus-inhibit-demon)
(defvar gnus-english-month-names)

;;; Internal Variables:

(defvar gnus-search-memo-query nil
  "Internal: stores current query.")

(defvar gnus-search-memo-server nil
  "Internal: stores current server.")

(defvar gnus-search-history ()
  "Internal history of Gnus searches.")

(define-error 'gnus-search-parse-error "Gnus search parsing error")

;;; User Customizable Variables:

(defgroup gnus-search nil
  "Search groups in Gnus with assorted search engines."
  :group 'gnus)

(defcustom gnus-search-use-parsed-queries t
  "When t, use Gnus' generalized search language.

The generalized search language is a sort of \"meta search\"
language that can be used across all search engines that Gnus
supports.  See the Gnus manual for details.

If this option is set to nil, search queries will be passed
directly to the search engines without being parsed or
transformed."
  :version "26.3"
  :type 'boolean
  :group 'gnus-search)

(defcustom gnus-search-ignored-newsgroups ""
  "A regexp to match newsgroups in the active file that should
  be skipped when searching."
  :version "24.1"
  :type 'regexp
  :group 'gnus-search)

;; Engine-specific configuration options.

(defcustom gnus-search-swish++-configuration-file
  (expand-file-name "~/Mail/swish++.conf")
  "Location of Swish++ configuration file.

This variable can also be set per-server."
  :type 'file
  :group 'gnus-search)

(defcustom gnus-search-swish++-program "search"
  "Name of swish++ search executable.

This variable can also be set per-server."
  :type 'string
  :group 'gnus-search)

(defcustom gnus-search-swish++-additional-switches '()
  "A list of strings, to be given as additional arguments to swish++.

Note that this should be a list.  I.e., do NOT use the following:
    (setq gnus-search-swish++-additional-switches \"-i -w\") ; wrong
Instead, use this:
    (setq gnus-search-swish++-additional-switches \\='(\"-i\" \"-w\"))

This variable can also be set per-server."
  :type '(repeat string)
  :group 'gnus-search)

(defcustom gnus-search-swish++-remove-prefix (concat (getenv "HOME") "/Mail/")
  "The prefix to remove from each file name returned by swish++
in order to get a group name (albeit with / instead of .).  This is a
regular expression.

This variable can also be set per-server."
  :type 'regexp
  :group 'gnus-search)

(defcustom gnus-search-swish++-raw-queries-p nil
  "If t, all Swish++ engines will only accept raw search query
  strings."
  :type 'boolean
  :version "26.3"
  :group 'gnus-search)

(defcustom gnus-search-swish-e-configuration-file
  (expand-file-name "~/Mail/swish-e.conf")
  "Configuration file for swish-e.

This variable can also be set per-server."
  :type 'file
  :group 'gnus-search)

(defcustom gnus-search-swish-e-program "search"
  "Name of swish-e search executable.

This variable can also be set per-server."
  :type 'string
  :group 'gnus-search)

(defcustom gnus-search-swish-e-additional-switches '()
  "A list of strings, to be given as additional arguments to swish-e.

Note that this should be a list.  I.e., do NOT use the following:
    (setq gnus-search-swish-e-additional-switches \"-i -w\") ; wrong
Instead, use this:
    (setq gnus-search-swish-e-additional-switches \\='(\"-i\" \"-w\"))

This variable can also be set per-server."
  :type '(repeat string)
  :group 'gnus-search)

(defcustom gnus-search-swish-e-remove-prefix (concat (getenv "HOME") "/Mail/")
  "The prefix to remove from each file name returned by swish-e
in order to get a group name (albeit with / instead of .).  This is a
regular expression.

This variable can also be set per-server."
  :type 'regexp
  :group 'gnus-search)

(defcustom gnus-search-swish-e-index-files '()
  "A list of index files to use with this Swish-e instance.

This variable can also be set per-server."
  :type '(repeat file)
  :group 'gnus-search)

(defcustom gnus-search-swish-e-raw-queries-p nil
  "If t, all Swish-e engines will only accept raw search query
  strings."
  :type 'boolean
  :version "26.3"
  :group 'gnus-search)

;; HyREX engine, see <URL:http://ls6-www.cs.uni-dortmund.de/>

(defcustom gnus-search-hyrex-program ""
  "Name of the hyrex search executable.

This variable can also be set per-server."
  :type 'string
  :group 'gnus-search)

(defcustom gnus-search-hyrex-additional-switches '()
  "A list of strings, to be given as additional arguments for hyrex search.
Note that this should be a list. I.e., do NOT use the following:
    (setq gnus-search-hyrex-additional-switches \"-ddl ddl.xml -c gnus-search\") ; wrong !
Instead, use this:
    (setq gnus-search-hyrex-additional-switches \\='(\"-ddl\" \"ddl.xml\" \"-c\" \"gnus-search\"))

This variable can also be set per-server."
  :type '(repeat string)
  :group 'gnus-search)

(defcustom gnus-search-hyrex-index-directory (getenv "HOME")
  "Index directory for HyREX.

This variable can also be set per-server."
  :type 'directory
  :group 'gnus-search)

(defcustom gnus-search-hyrex-remove-prefix (concat (getenv "HOME") "/Mail/")
  "The prefix to remove from each file name returned by HyREX
in order to get a group name (albeit with / instead of .).

For example, suppose that HyREX returns file names such as
\"/home/john/Mail/mail/misc/42\".  For this example, use the following
setting:  (setq gnus-search-hyrex-remove-prefix \"/home/john/Mail/\")
Note the trailing slash.  Removing this prefix gives \"mail/misc/42\".
`gnus-search' knows to remove the \"/42\" and to replace \"/\" with \".\" to
arrive at the correct group name, \"mail.misc\".

This variable can also be set per-server."
  :type 'directory
  :group 'gnus-search)

(defcustom gnus-search-hyrex-raw-queries-p nil
  "If t, all Hyrex engines will only accept raw search query
  strings."
  :type 'boolean
  :version "26.3"
  :group 'gnus-search)

;; Namazu engine, see <URL:http://www.namazu.org/>

(defcustom gnus-search-namazu-program "namazu"
  "Name of Namazu search executable.

This variable can also be set per-server."
  :type 'string
  :group 'gnus-search)

(defcustom gnus-search-namazu-index-directory (expand-file-name "~/Mail/namazu/")
  "Index directory for Namazu.

This variable can also be set per-server."
  :type 'directory
  :group 'gnus-search)

(defcustom gnus-search-namazu-additional-switches '()
  "A list of strings, to be given as additional arguments to namazu.
The switches `-q', `-a', and `-s' are always used, very few other switches
make any sense in this context.

Note that this should be a list.  I.e., do NOT use the following:
    (setq gnus-search-namazu-additional-switches \"-i -w\") ; wrong
Instead, use this:
    (setq gnus-search-namazu-additional-switches \\='(\"-i\" \"-w\"))

This variable can also be set per-server."
  :type '(repeat string)
  :group 'gnus-search)

(defcustom gnus-search-namazu-remove-prefix (concat (getenv "HOME") "/Mail/")
  "The prefix to remove from each file name returned by Namazu
in order to get a group name (albeit with / instead of .).

For example, suppose that Namazu returns file names such as
\"/home/john/Mail/mail/misc/42\".  For this example, use the following
setting:  (setq gnus-search-namazu-remove-prefix \"/home/john/Mail/\")
Note the trailing slash.  Removing this prefix gives \"mail/misc/42\".
Gnus knows to remove the \"/42\" and to replace \"/\" with \".\" to
arrive at the correct group name, \"mail.misc\".

This variable can also be set per-server."
  :type 'directory
  :group 'gnus-search)

(defcustom gnus-search-namazu-raw-queries-p nil
  "If t, all Namazu engines will only accept raw search query
  strings."
  :type 'boolean
  :version "26.3"
  :group 'gnus-search)

(defcustom gnus-search-notmuch-program "notmuch"
  "Name of notmuch search executable.

This variable can also be set per-server."
  :version "24.1"
  :type '(string)
  :group 'gnus-search)

(defcustom gnus-search-notmuch-configuration-file
  (expand-file-name "~/.notmuch-config")
  "Configuration file for notmuch.

This variable can also be set per-server."
  :type 'file
  :group 'gnus-search)

(defcustom gnus-search-notmuch-additional-switches '()
  "A list of strings, to be given as additional arguments to notmuch.

Note that this should be a list.  I.e., do NOT use the following:
    (setq gnus-search-notmuch-additional-switches \"-i -w\") ; wrong
Instead, use this:
    (setq gnus-search-notmuch-additional-switches \\='(\"-i\" \"-w\"))

This variable can also be set per-server."
  :version "24.1"
  :type '(repeat string)
  :group 'gnus-search)

(defcustom gnus-search-notmuch-remove-prefix (concat (getenv "HOME") "/Mail/")
  "The prefix to remove from each file name returned by notmuch
in order to get a group name (albeit with / instead of .).  This is a
regular expression.

This variable can also be set per-server."
  :version "24.1"
  :type 'regexp
  :group 'gnus-search)

(defcustom gnus-search-notmuch-raw-queries-p nil
  "If t, all Notmuch engines will only accept raw search query
  strings."
  :type 'boolean
  :version "26.3"
  :group 'gnus-search)

(defcustom gnus-search-imap-raw-queries-p nil
  "If t, all IMAP engines will only accept raw search query
  strings."
  :version "26.3"
  :type 'boolean
  :group 'gnus-search)

;; Options for search language parsing.

(defcustom gnus-search-expandable-keys
  '("from" "subject" "to" "cc" "bcc" "body" "recipient" "date"
    "mark" "contact" "contact-from" "contact-to" "before" "after"
    "larger" "smaller" "attachment" "text" "since" "thread"
    "sender" "address" "tag" "size")
  "A list of strings representing expandable search keys.

\"Expandable\" simply means the key can be abbreviated while
typing in search queries, ie \"subject\" could be entered as
\"subj\" or even \"su\", though \"s\" is ambigous between
\"subject\" and \"since\".

Keys can contain hyphens, in which case each section will be
expanded separately.  \"cont\" will expand to \"contact\", for
instance, while \"c-t\" will expand to \"contact-to\".

Ambiguous abbreviations will raise an error."
  :group 'gnus-search
  :version "26.1"
  :type '(repeat string))

(defcustom gnus-search-date-keys
  '("date" "before" "after" "on" "senton" "sentbefore" "sentsince" "since")
  "A list of keywords whose value should be parsed as a date.

See the docstring of `gnus-search-parse-query' for information on
date parsing."
  :group 'gnus-search
  :version "26.1"
  :type '(repeat string))

(defcustom gnus-search-contact-sources nil
  "A list of sources used to search for messages from contacts.

Each list element can be either a function, or an alist.
Functions should accept a search string, and return a list of
email addresses of matching contacts.  An alist should map single
strings to lists of mail addresses, usable as search keys in mail
headers."
  :group 'gnus-search
  :version "26.1"
  :type '(repeat (choice function
			 (alist
			  :key-type string
			  :value-type (repeat string)))))

;;; Search language

;; This "language" was generalized from the original IMAP search query
;; parsing routine.

(defun gnus-search-parse-query (string)
  "Turn STRING into an s-expression based query.

The resulting query structure is passed to the various search
backends, each of which adapts it as needed.

The search \"language\" is essentially a series of key:value
expressions.  Key is most often a mail header, but there are
other keys.  Value is a string, quoted if it contains spaces.
Key and value are separated by a colon, no space.  Expressions
are implictly ANDed; the \"or\" keyword can be used to
OR. \"not\" will negate the following expression, or keys can be
prefixed with a \"-\".  The \"near\" operator will work for
engines that understand it; other engines will convert it to
\"or\".  Parenthetical groups work as expected.

A key that matches the name of a mail header will search that
header.

Search keys can be abbreviated so long as they remain
unambiguous, ie \"f\" will search the \"from\" header. \"s\" will
raise an error.

Other keys:

\"address\" will search all sender and recipient headers.

\"recipient\" will search \"To\", \"Cc\", and \"Bcc\".

\"before\" will search messages sent before the specified
date (date specifications to come later).  Date is exclusive.

\"after\" (or its synonym \"since\") will search messages sent
after the specified date.  Date is inclusive.

\"mark\" will search messages that have some sort of mark.
Likely values include \"flag\", \"seen\", \"read\", \"replied\".
It's also possible to use Gnus' internal marks, ie \"mark:R\"
will be interpreted as mark:read.

\"tag\" will search tags -- right now that's translated to
\"keyword\" in IMAP, and left as \"tag\" for notmuch. At some
point this should also be used to search marks in the Gnus
registry.

\"contact\" will search messages to/from a contact.  Contact
management packages must push a function onto
`gnus-search-contact-sources', the docstring of which see, for
this to work.

\"contact-from\" does what you'd expect.

\"contact-to\" searches the same headers as \"recipient\".

Other keys can be specified, provided that the search backends
know how to interpret them.

Date values (any key in `gnus-search-date-keys') can be provided
in any format that `parse-time-string' can parse (note that this
can produce weird results).  Dates with missing bits will be
interpreted as the most recent occurance thereof (ie \"march 03\"
is the most recent March 3rd).  Lastly, relative specifications
such as 1d (one day ago) are understood.  This also accepts w, m,
and y.  m is assumed to be 30 days.

This function will accept pretty much anything as input.  Its
only job is to parse the query into a sexp, and pass that on --
it is the job of the search backends to make sense of the
structured query.  Malformed, unusable or invalid queries will
typically be silently ignored."
  (with-temp-buffer
    ;; Set up the parsing environment.
    (insert string)
    (goto-char (point-min))
    ;; Now, collect the output terms and return them.
    (let (out)
      (while (not (gnus-search-query-end-of-input))
	(push (gnus-search-query-next-expr) out))
      (reverse out))))

(defun gnus-search-query-next-expr (&optional count halt)
  "Return the next expression from the current buffer."
  (let ((term (gnus-search-query-next-term count))
	(next (gnus-search-query-peek-symbol)))
    ;; Deal with top-level expressions.  And, or, not, near...  What
    ;; else?  Notmuch also provides xor and adj.  It also provides a
    ;; "nearness" parameter for near and adj.
    (cond
     ;; Handle 'expr or expr'
     ((and (eq next 'or)
	   (null halt))
      (list 'or term (gnus-search-query-next-expr 2)))
     ;; Handle 'near operator.
     ((and (eq next 'near))
      (let ((near-next (gnus-search-query-next-expr 2)))
	(if (and (stringp term)
		 (stringp near-next))
	    (list 'near term near-next)
	  (signal 'gnus-search-parse-error
		  (list "\"Near\" keyword must appear between two plain strings.")))))
     ;; Anything else
     (t term))))

(defun gnus-search-query-next-term (&optional count)
  "Return the next TERM from the current buffer."
  (let ((term (gnus-search-query-next-symbol count)))
    ;; What sort of term is this?
    (cond
     ;; negated term
     ((eq term 'not) (list 'not (gnus-search-query-next-expr nil 'halt)))
     ;; generic term
     (t term))))

(defun gnus-search-query-peek-symbol ()
  "Return the next symbol from the current buffer, but don't consume it."
  (save-excursion
    (gnus-search-query-next-symbol)))

(defun gnus-search-query-next-symbol (&optional count)
  "Return the next symbol from the current buffer, or nil if we are
at the end of the buffer.  If supplied COUNT skips some symbols before
returning the one at the supplied position."
  (when (and (numberp count) (> count 1))
    (gnus-search-query-next-symbol (1- count)))
  (let ((case-fold-search t))
    ;; end of input stream?
    (unless (gnus-search-query-end-of-input)
      ;; No, return the next symbol from the stream.
      (cond
       ;; Negated expression -- return it and advance one char.
       ((looking-at "-") (forward-char 1) 'not)
       ;; List expression -- we parse the content and return this as a list.
       ((looking-at "(")
	(gnus-search-parse-query (gnus-search-query-return-string ")")))
       ;; Keyword input -- return a symbol version.
       ((looking-at "\\band\\b") (forward-char 3) 'and)
       ((looking-at "\\bor\\b")  (forward-char 2) 'or)
       ((looking-at "\\bnot\\b") (forward-char 3) 'not)
       ((looking-at "\\bnear\\b") (forward-char 4) 'near)
       ;; Plain string, no keyword
       ((looking-at "\"?\\b[^:]+\\([[:blank:]]\\|\\'\\)")
	(gnus-search-query-return-string
	 (when (looking-at "\"") "\"")))
       ;; Assume a K:V expression.
       (t (let ((key (gnus-search-query-expand-key
		      (buffer-substring
		       (point)
		       (progn
			 (re-search-forward ":" (point-at-eol) t)
			 (1- (point))))))
		(value (gnus-search-query-return-string
			(when (looking-at "\"") "\""))))
	    (gnus-search-query-parse-kv key value)))))))

(defun gnus-search-query-parse-kv (key value)
  "Handle KEY and VALUE, parsing and expanding as necessary.

This may result in (key value) being turned into a larger query
structure.

In the simplest case, they are simply consed together.  KEY comes
in as a string, goes out as a symbol."
  (let (return)
    (cond
     ((member key gnus-search-date-keys)
      (when (string= "after" key)
	(setq key "since"))
      (setq value (gnus-search-query-parse-date value)))
     ((string-match-p "contact" key)
      (setq return (gnus-search-query-parse-contact key value)))
     ((equal key "address")
      (setq return `(or (sender . ,value) (recipient . ,value))))
     ((equal key "mark")
      (setq value (gnus-search-query-parse-mark value))))
    (or return
	(cons (intern key) value))))

(defun gnus-search-query-parse-date (value &optional rel-date)
  "Interpret VALUE as a date specification.

See the docstring of `gnus-search-parse-query' for details.

The result is a list of (dd mm yyyy); individual elements can be
nil.

If VALUE is a relative time, interpret it as relative to
REL-DATE, or \(current-time\) if REL-DATE is nil."
  ;; Time parsing doesn't seem to work with slashes.
  (let ((value (replace-regexp-in-string "/" "-" value))
	(now (append '(0 0 0)
		     (seq-subseq (decode-time (or rel-date
						  (current-time)))
				 3))))
    ;; Check for relative time parsing.
    (if (string-match "\\([[:digit:]]+\\)\\([dwmy]\\)" value)
	(seq-subseq
	 (decode-time
	  (time-subtract
	   (apply #'encode-time now)
	   (days-to-time
	    (* (string-to-number (match-string 1 value))
	       (cdr (assoc (match-string 2 value)
			   '(("d" . 1)
			     ("w" . 7)
			     ("m" . 30)
			     ("y" . 365))))))))
	 3 6)
      ;; Otherwise check the value of `parse-time-string'.

      ;; (SEC MIN HOUR DAY MON YEAR DOW DST TZ)
      (let ((d-time (parse-time-string value)))
	;; Did parsing produce anything at all?
	(if (seq-some #'integerp (seq-subseq d-time 3 7))
	    (seq-subseq
	     ;; If DOW is given, handle that specially.
	     (if (and (seq-elt d-time 6) (null (seq-elt d-time 3)))
		 (decode-time
		  (time-subtract (apply #'encode-time now)
				 (days-to-time
				  (+ (if (> (seq-elt d-time 6)
					    (seq-elt now 6))
					 7 0)
				     (- (seq-elt now 6) (seq-elt d-time 6))))))
	       d-time)
	     3 6)
	  ;; `parse-time-string' failed to produce anything, just
	  ;; return the string.
	  value)))))

(defun gnus-search-query-parse-mark (mark)
  "Possibly transform MARK.

If MARK is a single character, assume it is one of the
gnus-*-mark marks, and return an appropriate string."
  (if (= 1 (length mark))
      (let ((m (aref mark 0)))
	;; Neither pcase nor cl-case will work here.
       (cond
	 ((eql m gnus-ticked-mark) "flag")
	 ((eql m gnus-read-mark) "read")
	 ((eql m gnus-replied-mark) "replied")
	 ((eql m gnus-recent-mark) "recent")
	 (t mark)))
    mark))

(defun gnus-search-query-parse-contact (key value)
  "Handle VALUE as the name of a contact.

Runs VALUE through the elements of
`gnus-search-contact-sources' until one of them returns a list
of email addresses.  Turns those addresses into an appropriate
chunk of query syntax."
  (let ((funcs (or (copy-sequence gnus-search-contact-sources)
		   (signal 'gnus-search-parse-error
		    (list "No functions for handling contacts."))))
	func addresses)
    (while (and (setq func (pop funcs))
		(null addresses))
      (setq addresses (if (functionp func)
			  (funcall func value)
			(when (string= value (car func))
			  (cdr func)))))
    (unless addresses
      (setq addresses (list value)))
    ;; Simplest case: single From address.
    (if (and (null (cdr addresses))
	     (equal key "contact-from"))
	(cons 'sender (car addresses))
      (cons
       'or
       (mapcan
	(lambda (a)
	  (pcase key
	    ("contact-from"
	     (list (cons 'sender a)))
	    ("contact-to"
	     (list (cons 'recipient a)))
	    ("contact"
	     `(or (recipient . ,a) (sender . ,a)))))
	addresses)))))

(defun gnus-search-query-expand-key (key)
  "Attempt to expand KEY to a full keyword."
  (let ((bits (split-string key "-"))
	bit out-bits comp)
    (if (try-completion (car bits) gnus-search-expandable-keys)
	(progn
	  (while (setq bit (pop bits))
	    (setq comp (try-completion bit gnus-search-expandable-keys))
	    (if (stringp comp)
		(if (and (string= bit comp)
			 (null (member comp gnus-search-expandable-keys)))
		    (signal 'gnus-search-parse-error
			    (list (format "Ambiguous keyword: %s" key)))
		  (push comp out-bits))
	      (push bit out-bits)))
	  (mapconcat #'identity (reverse out-bits) "-"))
      key)))

;; (defun gnus-search-query-expand-key (key)
;;   "Attempt to expand (possibly abbreviated) KEY to a full keyword.

;; Can handle any non-ambiguous abbreviation, with hyphens as substring separator."
;;   (let* ((bits (split-string key "-"))
;; 	 (bit (pop bits))
;; 	 (comp (all-completions bit gnus-search-expandable-keys)))
;;     ;; Make a cl-labels recursive function, that accepts a rebuilt key and
;;     ;; results of `all-completions' back in as a COLLECTION argument.
;;     (if (= 1 (length comp))
;; 	(setq key (car comp))
;;       (when (setq comp (try-completion bit gnus-search-expandable-keys))
;; 	(if (and (string= bit comp)
;; 		 (null (member comp gnus-search-expandable-keys)))
;; 	    (error "Ambiguous keyword: %s" key)))
;;       (unless (eq t (try-completion key gnus-search-expandable-keys))))
;;     key))


(defun gnus-search-query-return-string (&optional delimiter)
  "Return a string from the current buffer.

If DELIMITER is given, return everything between point and the
next occurance of DELIMITER.  Otherwise, return one word."
  (let ((start (point)) end)
    (if delimiter
	(progn
	  (forward-char 1)		; skip the first delimiter.
	  (while (not end)
	    (unless (search-forward delimiter nil t)
	      (signal 'gnus-search-parse-error
		      (list (format "Unmatched delimited input with %s in query" delimiter))))
	    (let ((here (point)))
	      (unless (equal (buffer-substring (- here 2) (- here 1)) "\\")
		(setq end (1- (point))
		      start (1+ start))))))
      (setq end (progn (re-search-forward "\\([[:blank:]]+\\|$\\)" (point-max) t)
		       (match-beginning 0))))
    (buffer-substring start end)))

(defun gnus-search-query-end-of-input ()
  "Are we at the end of input?"
  (skip-chars-forward "[[:blank:]]")
  (looking-at "$"))

(defmacro gnus-search-add-result (dirnam artno score prefix server artlist)
  "Ask `gnus-search-compose-result' to construct a result vector,
and if it is non-nil, add it to artlist."
  `(let ((result (gnus-search-compose-result ,dirnam ,artno ,score ,prefix ,server) ))
     (when (not (null result))
       (push result ,artlist))))

(autoload 'nnmaildir-base-name-to-article-number "nnmaildir")

(defun gnus-search-compose-result (dirnam article score prefix server)
  "Extract the group from dirnam, and create a result vector
ready to be added to the list of search results."

  ;; remove gnus-search-*-remove-prefix from beginning of dirnam filename
  (when (string-match (concat "^"
			      (file-name-as-directory prefix))
		      dirnam)
    (setq dirnam (replace-match "" t t dirnam)))

  (when (file-readable-p (concat prefix dirnam article))
    ;; remove trailing slash and, for nnmaildir, cur/new/tmp
    (setq dirnam
	  (replace-regexp-in-string
	   "/?\\(cur\\|new\\|tmp\\)?/\\'" "" dirnam))

    ;; Set group to dirnam without any leading dots or slashes,
    ;; and with all subsequent slashes replaced by dots
    (let ((group (replace-regexp-in-string
		  "[/\\]" "."
		  (replace-regexp-in-string "^[./\\]" "" dirnam nil t)
		  nil t)))

      (vector (gnus-group-full-name group server)
	      (if (string-match-p "\\`[[:digit:]]+\\'" article)
		  (string-to-number article)
		(nnmaildir-base-name-to-article-number
		 (substring article 0 (string-match ":" article))
		 group nil))
	      (string-to-number score)))))

;;; Search engines

;; Search engines are implemented as classes.  This is good for two
;; things: encapsulating things like indexes and search prefixes, and
;; transforming search queries.

(defclass gnus-search-engine ()
  ((raw-queries-p
    :initarg :raw-queries-p
    :initform nil
    :type boolean
    :custom boolean
    :documentation
    "When t, searches through this engine will never be parsed or
    transformed, and must be entered \"raw\"."))
  :abstract t
  :documentation "Abstract base class for Gnus search engines.")

(defclass gnus-search-process ()
  ((proc-buffer
    :initarg :proc-buffer
    :type buffer
    :documentation "A temporary buffer this engine uses for its
    search process, and for munging its search results."))
  :abstract t
  :documentation
  "A mixin class for engines that do their searching in a single
  process launched for this purpose, which returns at the end of
  the search.  Subclass instances are safe to be run in
  threads.")

(cl-defmethod shared-initialize ((engine gnus-search-process)
				 slots)
  (setq slots (plist-put slots :proc-buffer
			 (get-buffer-create
			  (generate-new-buffer-name " *gnus-search-"))))
  (cl-call-next-method engine slots))

(defclass gnus-search-imap (gnus-search-engine)
  ((literal-plus
    :initarg :literal-plus
    :initform nil
    :type boolean
    :documentation
    "Can this search engine handle literal+ searches?  This slot
    is set automatically by the imap server, and cannot be
    set manually.  Only the LITERAL+ capability is handled.")
   (multisearch
    :initarg :multisearch
    :iniformt nil
    :type boolean
    :documentation
    "Can this search engine handle the MULTISEARCH capability?
    This slot is set automatically by the imap server, and cannot
    be set manually.  Currently unimplemented.")
   (fuzzy
    :initarg :fuzzy
    :iniformt nil
    :type boolean
    :documentation
    "Can this search engine handle the FUZZY search capability?
    This slot is set automatically by the imap server, and cannot
    be set manually.  Currently unimplemented."))
  :documentation
  "The base IMAP search engine, using an IMAP server's search capabilites.

This backend may be subclassed to handle particular IMAP servers'
quirks.")

(eieio-oset-default 'gnus-search-imap 'raw-queries-p
		    gnus-search-imap-raw-queries-p)

(defclass gnus-search-find-grep (gnus-search-engine gnus-search-process)
  nil)

(defclass gnus-search-gmane (gnus-search-engine gnus-search-process)
  nil)

;;; The "indexed" search engine.  These are engines that use an
;;; external program, with indexes kept on disk, to search messages
;;; usually kept in some local directory.  The three common slots are
;;; "program", holding the string name of the executable; "switches",
;;; holding additional switches to pass to the executable; and
;;; "prefix", which is sort of the path to the found messages which
;;; should be removed so that Gnus can find them.  Many of the
;;; subclasses also allow distinguishing multiple databases or
;;; indexes.  These slots can be set using a global default, or on a
;;; per-server basis.

(defclass gnus-search-indexed (gnus-search-engine gnus-search-process)
  ((program
    :initarg :program
    :type string
    :documentation
    "The executable used for indexing and searching.")
   (prefix
    :initarg :prefix
    :type string
    :documentation
    "The path to the directory where the indexed mails are
    kept. This path is removed from the search results.")
   (switches
    :initarg :switches
    :type list
    :documentation
    "Additional switches passed to the search engine command-line
    program."))
    :abstract t
  :allow-nil-initform t
  :documentation "A base search engine class that assumes a local search index
  accessed by a command line program.")

(eieio-oset-default 'gnus-search-indexed 'prefix
		    (concat (getenv "HOME") "/Mail/"))

(defclass gnus-search-swish-e (gnus-search-indexed)
  ((index-files
    :init-arg :index-files
    :type list)))

(eieio-oset-default 'gnus-search-swish-e 'program
		    gnus-search-swish-e-program)

(eieio-oset-default 'gnus-search-swish-e 'prefix
		    gnus-search-swish-e-remove-prefix)

(eieio-oset-default 'gnus-search-swish-e 'index-files
		    gnus-search-swish-e-index-files)

(eieio-oset-default 'gnus-search-swish-e 'switches
		    gnus-search-swish-e-additional-switches)

(eieio-oset-default 'gnus-search-swish-e 'raw-queries-p
		    gnus-search-swish-e-raw-queries-p)

(defclass gnus-search-swish++ (gnus-search-indexed)
  ((config-file
    :init-arg :config-file
    :type string)))

(eieio-oset-default 'gnus-search-swish++ 'program
		    gnus-search-swish++-program)

(eieio-oset-default 'gnus-search-swish++ 'prefix
		    gnus-search-swish++-remove-prefix)

(eieio-oset-default 'gnus-search-swish++ 'config-file
		    gnus-search-swish++-configuration-file)

(eieio-oset-default 'gnus-search-swish++ 'switches
		    gnus-search-swish++-additional-switches)

(eieio-oset-default 'gnus-search-swish++ 'raw-queries-p
		    gnus-search-swish++-raw-queries-p)

(defclass gnus-search-hyrex (gnus-search-indexed)
  ((index-dir
    :initarg :index
    :type string
    :custom directory)))

(eieio-oset-default 'gnus-search-hyrex 'program
		    gnus-search-hyrex-program)

(eieio-oset-default 'gnus-search-hyrex 'index-dir
		    gnus-search-hyrex-index-directory)

(eieio-oset-default 'gnus-search-hyrex 'switches
		    gnus-search-hyrex-additional-switches)

(eieio-oset-default 'gnus-search-hyrex 'prefix
		    gnus-search-hyrex-remove-prefix)

(eieio-oset-default 'gnus-search-hyrex 'raw-queries-p
		    gnus-search-hyrex-raw-queries-p)

(defclass gnus-search-namazu (gnus-search-indexed)
  ((index-dir
    :initarg :index-dir
    :type string
    :custom directory)))

(eieio-oset-default 'gnus-search-namazu 'program
		    gnus-search-namazu-program)

(eieio-oset-default 'gnus-search-namazu 'index-dir
		    gnus-search-namazu-index-directory)

(eieio-oset-default 'gnus-search-namazu 'switches
		    gnus-search-namazu-additional-switches)

(eieio-oset-default 'gnus-search-namazu 'prefix
		    gnus-search-namazu-remove-prefix)

(eieio-oset-default 'gnus-search-namazu 'raw-queries-p
		    gnus-search-namazu-raw-queries-p)

(defclass gnus-search-notmuch (gnus-search-indexed)
  ((config-file
    :init-arg :config-file
    :type string)))

(eieio-oset-default 'gnus-search-notmuch 'program
		    gnus-search-notmuch-program)

(eieio-oset-default 'gnus-search-notmuch 'switches
		    gnus-search-notmuch-additional-switches)

(eieio-oset-default 'gnus-search-notmuch 'prefix
		    gnus-search-notmuch-remove-prefix)

(eieio-oset-default 'gnus-search-notmuch 'config-file
		    gnus-search-notmuch-configuration-file)

(eieio-oset-default 'gnus-search-notmuch 'raw-queries-p
		    gnus-search-notmuch-raw-queries-p)

(defcustom gnus-search-default-engines '((nnimap gnus-search-imap)
					 (nntp  gnus-search-gmane))
  "Alist of default search engines keyed by server method."
  :version "26.1"
  :group 'gnus-search
  :type `(repeat (list (choice (const nnimap) (const nntp) (const nnspool)
			       (const nneething) (const nndir) (const nnmbox)
			       (const nnml) (const nnmh) (const nndraft)
			       (const nnfolder) (const nnmaildir))
		       (choice
			,@(mapcar
			   (lambda (el) (list 'const (intern (car el))))
			   (eieio-build-class-alist 'gnus-search-engine t))))))

;;; Transforming and running search queries.

(cl-defgeneric gnus-search-run-search (backend server query groups)
  "Run QUERY in GROUPS against SERVER, using search BACKEND.

Should return results as a vector of vectors.")

(cl-defgeneric gnus-search-transform (backend expression)
  "Transform sexp EXPRESSION into a string search query usable by BACKEND.

Responsible for handling and, or, and parenthetical expressions.")

(cl-defgeneric gnus-search-transform-expression (backend expression)
  "Transform a basic EXPRESSION into a string usable by BACKEND.")

;; Methods that are likely to be the same for all engines.

(cl-defmethod gnus-search-transform ((engine gnus-search-engine)
					       (query list))
  (let (clauses)
   (mapc
    (lambda (item)
      (when-let ((expr (gnus-search-transform-expression engine item)))
	(push expr clauses)))
    query)
   (mapconcat #'identity (reverse clauses) " ")))

;; Most search engines want quoted string phrases.
(cl-defmethod gnus-search-transform-expression ((_ gnus-search-engine)
						(expr string))
  (if (string-match-p " " expr)
      (format "\"%s\"" expr)
    expr))

;; Most search engines use implicit ANDs.
(cl-defmethod gnus-search-transform-expression ((_ gnus-search-engine)
						(_expr (eql and)))
  nil)

;; Most search engines use explicit infixed ORs.
(cl-defmethod gnus-search-transform-expression ((engine gnus-search-engine)
						(expr (head or)))
  (let ((left (gnus-search-transform-expression engine (nth 1 expr)))
	(right (gnus-search-transform-expression engine (nth 2 expr))))
    ;; Unhandled keywords return a nil; don't create an "or" expression
    ;; unless both sub-expressions are non-nil.
    (if (and left right)
	(format "%s or %s" left right)
      (or left right))))

;; Most search engines just use the string "not"
(cl-defmethod gnus-search-transform-expression ((engine gnus-search-engine)
						(expr (head not)))
  (let ((next (gnus-search-transform-expression engine (cadr expr))))
    (when next
     (format "not %s" next))))

;;; Search Engine Interfaces:

(autoload 'nnimap-change-group "nnimap")
(declare-function nnimap-buffer "nnimap" ())
(declare-function nnimap-command "nnimap" (&rest args))

;; imap interface
(cl-defmethod gnus-search-run-search ((engine gnus-search-imap)
			       srv query groups)
  (save-excursion
    (let ((server (cadr (gnus-server-to-method srv)))
          (gnus-inhibit-demon t))
      (message "Opening server %s" server)
      ;; We should only be doing this once, in
      ;; `nnimap-open-connection', but it's too frustrating to try to
      ;; get to the server from the process buffer.
      (with-current-buffer (nnimap-buffer)
	(setf (slot-value engine 'literal-plus)
	      (when (nnimap-capability "LITERAL+") t))
	;; MULTISEARCH not yet implemented.
	(setf (slot-value engine 'multisearch)
	      (when (nnimap-capability "MULTISEARCH") t)))
      (when (listp query)
       (setq query
	     (gnus-search-transform
	      engine query)))
      (apply
       'vconcat
       (mapcar
	(lambda (group)
	  (let (artlist)
	    (condition-case ()
		(when (nnimap-change-group
		       (gnus-group-short-name group) server)
		  (with-current-buffer (nnimap-buffer)
		    (message "Searching %s..." group)
		    (let ((arts 0)
			  (result
			   (gnus-search-imap-search-command engine query)))
		      (mapc
		       (lambda (artnum)
			 (let ((artn (string-to-number artnum)))
			   (when (> artn 0)
			     (push (vector group artn 100)
				   artlist)
			     (setq arts (1+ arts)))))
		       (and (car result)
			    (cdr (assoc "SEARCH" (cdr result)))))
		      (message "Searching %s... %d matches" group arts)))
		  (message "Searching %s...done" group))
	      (quit nil))
	    (nreverse artlist)))
	groups)))))

(cl-defmethod gnus-search-imap-search-command ((engine gnus-search-imap)
					(query string))
  "Create the IMAP search command for QUERY.

Currenly takes into account support for the LITERAL+ capability.
Other capabilities could be tested here."
  (with-slots (literal-plus) engine
    (when literal-plus
      (setq query (split-string query "\n")))
    (cond
     ((consp query)
      ;; We're not really streaming, just need to prevent
      ;; `nnimap-send-command' from waiting for a response.
      (let* ((nnimap-streaming t)
	     (call
	      (nnimap-send-command
	       "UID SEARCH CHARSET UTF-8 %s"
	       (pop query))))
	(dolist (l query)
	  (process-send-string (get-buffer-process (current-buffer)) l)
	  (process-send-string (get-buffer-process (current-buffer))
			       (if (nnimap-newlinep nnimap-object)
				   "\n"
				 "\r\n")))
	(nnimap-get-response call)))
     (t (nnimap-command "UID SEARCH %s" query)))))

;; TODO: Don't exclude booleans and date keys, just check for them
;; before checking for general keywords.
(defvar gnus-search-imap-search-keys
  '(body cc from header keyword larger smaller subject text to uid)
  "Known IMAP search keys, excluding booleans and date keys.")

(cl-defmethod gnus-search-transform ((_ gnus-search-imap)
					       (_query null))
  "ALL")

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-imap)
						(expr string))
  (format "TEXT %s" (gnus-search-imap-handle-string engine expr)))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-imap)
						(expr (head or)))
  (let ((left (gnus-search-transform-expression engine (nth 1 expr)))
	(right (gnus-search-transform-expression engine (nth 2 expr))))
    (if (and left right)
	(format "OR %s %s" left right)
      (or left right))))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-imap)
						(expr (head near)))
  "Imap searches interpret \"near\" as \"or\"."
  (setcar expr 'or)
  (gnus-search-transform-expression engine expr))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-imap)
						(expr (head not)))
  "Transform IMAP NOT.

If the term to be negated is a flag, then use the appropriate UN*
boolean instead."
  (if (eql (caadr expr) 'mark)
      (if (string= (cdadr expr) "new")
	  "OLD"
	(format "UN%s" (gnus-search-imap-handle-flag (cdadr expr))))
    (format "NOT %s"
	    (gnus-search-transform-expression engine (cadr expr)))))

(cl-defmethod gnus-search-transform-expression ((_ gnus-search-imap)
						(expr (head mark)))
  (gnus-search-imap-handle-flag (cdr expr)))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-imap)
						(expr list))
  ;; Search keyword.  All IMAP search keywords that take a value are
  ;; supported directly.  Keywords that are boolean are supported
  ;; through other means (usually the "mark" keyword).
  (cl-case (car expr)
    (date (setcar expr 'on))
    (tag (setcar expr 'keyword)))
  (cond
   ((consp (car expr))
    (format "(%s)" (gnus-search-transform engine expr)))
   ((eq (car expr) 'sender)
    (format "FROM %s" (cdr expr)))
   ((eq (car expr) 'recipient)
    (format "OR (OR TO %s CC %s) BCC %s" (cdr expr) (cdr expr) (cdr expr)))
   ((memq (car expr) gnus-search-imap-search-keys)
    (format "%s %s"
	    (upcase (symbol-name (car expr)))
	    (gnus-search-imap-handle-string engine (cdr expr))))
   ((memq (car expr) '(before since on sentbefore senton sentsince))
    ;; Ignore dates given as strings.
    (when (listp (cdr expr))
      (format "%s %s"
	      (upcase (symbol-name (car expr)))
	      (gnus-search-imap-handle-date engine (cdr expr)))))
   ((eq (car expr) 'id)
    (format "HEADER Message-ID %s" (cdr expr)))
   ;; Treat what can't be handled as a HEADER search.  Probably a bad
   ;; idea.
   (t (format "HEADER %s %s"
	      (car expr)
	      (gnus-search-imap-handle-string engine (cdr expr))))))

(cl-defmethod gnus-search-imap-handle-date ((_engine gnus-search-imap)
				     (date list))
  "Turn DATE into a date string recognizable by IMAP.

While other search engines can interpret partially-qualified
dates such as a plain \"January\", IMAP requires an absolute
date.

DATE is a list of (dd mm yyyy), any element of which could be
nil.  Massage those numbers into the most recent past occurrence
of whichever date elements are present."
  (let ((now (decode-time (current-time))))
    ;; Set nil values to 1, current-month, current-year, or else 1, 1,
    ;; current-year, depending on what we think the user meant.
    (unless (seq-elt date 1)
      (setf (seq-elt date 1)
	    (if (seq-elt date 0)
		(seq-elt now 4)
	      1)))
    (unless (seq-elt date 0)
      (setf (seq-elt date 0) 1))
    (unless (seq-elt date 2)
      (setf (seq-elt date 2)
	    (seq-elt now 5)))
    ;; Fiddle with the date until it's in the past.  There
    ;; must be a way to combine all these steps.
    (unless (< (seq-elt date 2)
	       (seq-elt now 5))
      (when (< (seq-elt now 3)
	       (seq-elt date 0))
	(cl-decf (seq-elt date 1)))
      (cond ((zerop (seq-elt date 1))
	     (setf (seq-elt date 1) 1)
	     (cl-decf (seq-elt date 2)))
	    ((< (seq-elt now 4)
		(seq-elt date 1))
	     (cl-decf (seq-elt date 2))))))
  (format-time-string "%e-%b-%Y" (apply #'encode-time
					(append '(0 0 0)
						date))))

(cl-defmethod gnus-search-imap-handle-string ((engine gnus-search-imap)
				       (str string))
  (with-slots (literal-plus) engine
    ;; STR is not ASCII.
    (if (null (= (length str)
		 (string-bytes str)))
	(if literal-plus
	    ;; If LITERAL+ is available, use it and force UTF-8.
	    (format "{%d+}\n%s"
		    (string-bytes str)
		    (encode-coding-string str 'utf-8))
	  ;; Other servers might be able to parse it if quoted.
	  (format "\"%s\"" str))
      (if (string-match-p " " str)
	  (format "\"%s\"" str)
       str))))

(defun gnus-search-imap-handle-flag (flag)
  "Make sure string FLAG is something IMAP will recognize."
  ;; What else?  What about the KEYWORD search key?
  (setq flag
	(pcase flag
	  ("flag" "flagged")
	  ("read" "seen")
	  (_ flag)))
  (if (member flag '("seen" "answered" "deleted" "draft" "flagged"))
      (upcase flag)
    ""))

;;; Methods for the indexed search engines.

;; First, some common methods.

(cl-defgeneric gnus-search-indexed-massage-output (engine server &optional groups)
  "Massage the results of ENGINE's query against SERVER in GROUPS.

Most indexed search engines return results as a list of filenames
or something similar.  Turn those results into something Gnus
understands.")

(cl-defmethod gnus-search-run-search ((engine gnus-search-indexed)
			       server query groups)
  "Run QUERY against SERVER using ENGINE.

This method is common to all indexed search engines.

Returns a vector of [group name, file name, score] vectors."

  (save-excursion
    (let* ((qstring (if (listp query)
			(gnus-search-transform engine query)
		      query))
	   (program (slot-value engine 'program))
	   (buffer (slot-value engine 'proc-buffer))
	   (cp-list (gnus-search-indexed-search-command
		     engine qstring groups))
           proc exitstatus artlist)
      (set-buffer buffer)
      (erase-buffer)

      (if groups
	  (message "Doing %s query on %s..." program groups)
	(message "Doing %s query..." program))
      (setq proc (apply #'start-process "search" buffer program cp-list))

      (accept-process-output proc)
      (setq exitstatus (process-exit-status proc))
      (if (zerop exitstatus)
	  ;; The search results have been put into the current buffer;
	  ;; `massage-output' finds them there.
	  (progn
	    (setq artlist (gnus-search-indexed-massage-output
			   engine server groups))

	    ;; Sort by score

	    (apply #'vector
		   (sort artlist
			 (function (lambda (x y)
				     (> (nnselect-artitem-rsv x)
					(nnselect-artitem-rsv y)))))))
	(nnheader-report 'search "%s error: %s" program exitstatus)
	;; Failure reason is in this buffer, show it if the user
	;; wants it.
	(when (> gnus-verbose 6)
	  (display-buffer buffer))))))

(cl-defmethod gnus-search-indexed-massage-output ((engine gnus-search-indexed)
						  server &optional groups)
  "Common method for massaging filenames returned by indexed
search engines.

This method assumes that the engine returns a plain list of
absolute filepaths to standard out."
  ;; This method was originally the namazu-specific method.  I'm
  ;; almost certain that all the engines can use this same method
  ;; (meaning some fairly significant code reduction), but I haven't
  ;; gone and tested them all yet.

  ;; What if the server backend is nnml, and/or uses mboxes?
  (let ((article-pattern (if (string-match "\\'nnmaildir:"
					   (gnus-group-server server))
			     ":[0-9]+"
			   "^[0-9]+$"))
	(prefix (slot-value engine 'prefix))
	(group-regexp (when groups
			(regexp-opt
			 (mapcar
			  (lambda (x) (gnus-group-real-name x))
			  groups))))
	score group article artlist)
    (goto-char (point-min))
    (while (re-search-forward
	    "^\\([0-9,]+\\.\\).*\\((score: \\([0-9]+\\)\\))\n\\([^ ]+\\)"
	    nil t)
      (setq score (match-string 3)
	    group (file-name-directory (match-string 4))
	    article (file-name-nondirectory (match-string 4)))

      ;; make sure article and group is sane
      (when (and (string-match article-pattern article)
		 (not (null group))
		 (or (null group-regexp)
		     (string-match-p group-regexp group)))
	(gnus-search-add-result group article score prefix server artlist)))
    artlist))

;; Swish++

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-swish++)
						(expr (head near)))
  (format "%s near %s"
	  (gnus-search-transform-expression engine (nth 1 expr))
	  (gnus-search-transform-expression engine (nth 2 expr))))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-swish++)
						(expr list))
  (cond
   ((listp (car expr))
    (format "(%s)" (gnus-search-transform engine expr)))
   ;; Untested and likely wrong.
   ((and (stringp (cdr expr))
	 (string-prefix-p "(" (cdr expr)))
    (format "%s = %s" (car expr) (gnus-search-transform
				  engine
				  (gnus-search-parse-query (cdr expr)))))
   (t (format "%s = %s" (car expr) (cdr expr)))))

(cl-defmethod gnus-search-indexed-search-command ((engine gnus-search-swish++)
						  (qstring string))
  (with-slots (config-file switches) engine
   `("--config-file" ,config-file
     ,@switches
     ,qstring
     )))

(cl-defmethod gnus-search-indexed-massage-output ((engine gnus-search-swish++)
						  server &optional groups)
  (let ((groupspec (when groups
		     (regexp-opt
		      (mapcar
		       (lambda (x) (gnus-group-real-name x))
		       groups))))
	(prefix (slot-value engine 'prefix))
	(article-pattern (if (string-match "\\`nnmaildir:"
					   (gnus-group-server server))
			     ":[0-9]+"
			   "^[0-9]+\\(\\.[a-z0-9]+\\)?$"))
	filenam dirnam artno score artlist)
    (goto-char (point-min))
    (while (re-search-forward
            "\\(^[0-9]+\\) \\([^ ]+\\) [0-9]+ \\(.*\\)$" nil t)
      (setq score (match-string 1)
	    filenam (match-string 2)
            artno (file-name-nondirectory filenam)
            dirnam (file-name-directory filenam))

      ;; don't match directories
      (when (string-match article-pattern artno)
	(when (not (null dirnam))

	  ;; maybe limit results to matching groups.
	  (when (or (not groupspec)
		    (string-match groupspec dirnam))
	    (gnus-search-add-result dirnam artno score prefix server artlist)))))))

;; Swish-e

;; I didn't do the query transformation for Swish-e, because the
;; program seems no longer to exist.

(cl-defmethod gnus-search-indexed-search-command ((engine gnus-search-swish-e)
						  (qstring string))
  (with-slots (index-files switches) engine
    `("-f" ,@index-files
      ,@switches
      "-w"
      ,qstring
      )))

(cl-defmethod gnus-search-indexed-massage-output ((engine gnus-search-swish-e)
						  server &optional _groups)
  (let ((prefix (slot-value engine 'prefix))
	group dirnam artno score artlist)
    (goto-char (point-min))
    (while (re-search-forward
            "\\(^[0-9]+\\) \\([^ ]+\\) \"\\([^\"]+\\)\" [0-9]+$" nil t)
      (setq score (match-string 1)
            artno (match-string 3)
            dirnam (file-name-directory (match-string 2)))
      (when (string-match "^[0-9]+$" artno)
          (when (not (null dirnam))

	    ;; remove gnus-search-swish-e-remove-prefix from beginning of dirname
            (when (string-match (concat "^" prefix) dirnam)
              (setq dirnam (replace-match "" t t dirnam)))

            (setq dirnam (substring dirnam 0 -1))
	    ;; eliminate all ".", "/", "\" from beginning. Always matches.
            (string-match "^[./\\]*\\(.*\\)$" dirnam)
            ;; "/" -> "."
            (setq group (replace-regexp-in-string
			 "/" "." (match-string 1 dirnam)))
            ;; Windows "\\" -> "."
            (setq group (replace-regexp-in-string "\\\\" "." group))

            (push (vector (gnus-group-full-name group server)
                          (string-to-number artno)
                          (string-to-number score))
                  artlist))))))

;; HyREX interface

;; I have no idea what the hyrex search language looks like, and
;; suspect that the software isn't even supported anymore.

(cl-defmethod gnus-search-indexed-search-command ((engine gnus-search-hyrex)
						  (qstring string))
  (with-slots (program index-dir switches) engine
   `("-i" ,index-dir
     ,@switches
     ,qstring			   ; the query, in hyrex-search format
     )))

(cl-defmethod gnus-search-indexed-massage-output ((engine gnus-search-hyrex)
						  server &optional groups)
  (let ((groupspec (when groups
		     (regexp-opt
		      (mapcar
		       (lambda (x) (gnus-group-real-name x))
		       groups))))
	(prefix (slot-value engine 'prefix))
	dirnam artno score artlist)
    (goto-char (point-min))
    (keep-lines "^\\S + [0-9]+ [0-9]+$")
    ;; HyREX doesn't search directly in groups -- so filter out here.
    (when groupspec
      (keep-lines groupspec))
    ;; extract data from result lines
    (goto-char (point-min))
    (while (re-search-forward
	    "\\(\\S +\\) \\([0-9]+\\) \\([0-9]+\\)" nil t)
      (setq dirnam (match-string 1)
	    artno (match-string 2)
	    score (match-string 3))
      (when (string-match prefix dirnam)
	(setq dirnam (replace-match "" t t dirnam)))
      (push (vector (gnus-group-full-name
                     (replace-regexp-in-string "/" "." dirnam) server)
		    (string-to-number artno)
		    (string-to-number score))
	    artlist))
    artlist))

;; Namazu interface

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-namazu)
						(expr list))
  (cond
   ((listp (car expr))
    (format "(%s)" (gnus-search-transform engine expr)))
   ;; I have no idea which fields namazu can handle.  Just do these
   ;; for now.
   ((memq (car expr) '(subject from to))
    (format "+%s:%s" (car expr) (cdr expr)))
   ((eq (car expr) 'id)
    (format "+message-id:%s" (cdr expr)))
   (t (ignore-errors (cl-call-next-method)))))

;; I can't tell if this is actually necessary.
(cl-defmethod gnus-search-run-search :around ((_e gnus-search-namazu)
				       _server _query _groups)
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "LC_MESSAGES" "C")
    (cl-call-next-method)))

(cl-defmethod search-indexed-search-command ((engine gnus-search-namazu)
					     (qstring string))
  (with-slots (switches index-dir) engine
   `("-q"				; don't be verbose
      "-a"				; show all matches
      "-s"				; use short format
      ,@switches
      ,qstring				; the query, in namazu format
      ,index-dir ; index directory
      )))

;;; Notmuch interface

(cl-defmethod gnus-search-transform ((_engine gnus-search-notmuch)
					       (_query null))
  "*")

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-notmuch)
						(expr (head near)))
  (format "%s near %s"
	  (gnus-search-transform-expression engine (nth 1 expr))
	  (gnus-search-transform-expression engine (nth 2 expr))))

(cl-defmethod gnus-search-transform-expression ((engine gnus-search-notmuch)
						(expr list))
  ;; Swap keywords as necessary.
  (cl-case (car expr)
    (sender (setcar expr 'from))
    (recipient (setcar expr 'to))
    (mark (setcar expr 'tag)))
  ;; Then actually format the results.
  (cl-flet ((notmuch-date (date)
			  (if (stringp date)
			      date
			    (pcase date
			      (`(nil ,m nil)
			       (nth (1- m) gnus-english-month-names))
			      (`(nil nil ,y)
			       (number-to-string y))
			      (`(,d ,m nil)
			       (format "%02d-%02d" d m))
			      (`(nil ,m ,y)
			       (format "%02d-%d" m y))
			      (`(,d ,m ,y)
			       (format "%d/%d/%d" m d y))))))
    (cond
     ((consp (car expr))
      (format "(%s)") (gnus-search-transform engine expr))
     ((memq (car expr) '(from to subject attachment mimetype tag id
			      thread folder path lastmod query property))
      (format "%s:%s" (car expr) (if (string-match-p " " (cdr expr))
				     (format "\"%s\"" (cdr expr))
				   (cdr expr))))
     ((eq (car expr) 'date)
      (format "date:%s" (notmuch-date (cdr expr))))
     ((eq (car expr) 'before)
      (format "date:..%s" (notmuch-date (cdr expr))))
     ((eq (car expr) 'since)
      (format "date:%s.." (notmuch-date (cdr expr))))
     (t (ignore-errors (cl-call-next-method))))))

(cl-defmethod gnus-search-indexed-search-command ((engine gnus-search-notmuch)
						  (qstring string)
						  &optional _groups)
  ;; Theoretically we could use the GROUPS parameter to pass a
  ;; --folder switch to notmuch, but I'm not confident of getting the
  ;; format right.
  (with-slots (switches config-file) engine
    `(,(format "--config=%s" config-file)
      "search"
      "--format=text"
      "--output=files"
      ,@switches
      ,qstring				; the query, in notmuch format
      )))

(cl-defmethod gnus-search-indexed-massage-output ((engine gnus-search-notmuch)
						  server &optional groups)
  ;; The results are output in the format of:
  ;; absolute-path-name
  (let ((article-pattern (if (string-match "\\`nnmaildir:"
					   (gnus-group-server server))
			     ":[0-9]+"
			   "^[0-9]+$"))
	(prefix (slot-value engine 'prefix))
	(group-regexp (when groups
			(regexp-opt
			 (mapcar
			  (lambda (x) (gnus-group-real-name x))
			  groups))))
	artno dirnam filenam artlist)
    (goto-char (point-min))
    (while (not (eobp))
      (setq filenam (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position))
            artno (file-name-nondirectory filenam)
            dirnam (file-name-directory filenam))
      (forward-line 1)

      ;; don't match directories
      (when (string-match article-pattern artno)
	(when (not (null dirnam))

	  ;; maybe limit results to matching groups.
	  (when (or (not groups)
		    (string-match-p group-regexp dirnam))
	    (gnus-search-add-result dirnam artno "" prefix server artlist)))))
    artlist))

;;; Find-grep interface

(cl-defmethod gnus-search-run-search ((engine gnus-search-find-grep)
			       server query
			       &optional groups)
  "Run find and grep to obtain matching articles."
  (let* ((method (gnus-server-to-method server))
	 (sym (intern
	       (concat (symbol-name (car method)) "-directory")))
	 (directory (cadr (assoc sym (cddr method))))
	 (regexp (cdr (assoc 'query query)))
	 ;; `grep-options' will actually come out of the parsed query.
	 (grep-options (cdr (assoc 'grep-options query)))
	 (grouplist (or groups (gnus-search-get-active server)))
	 (buffer (slot-value engine 'proc-buffer)))
    (unless directory
      (error "No directory found in method specification of server %s"
	     server))
    (apply
     'vconcat
     (mapcar (lambda (x)
	       (let ((group x)
		     artlist)
		 (message "Searching %s using find-grep..."
			  (or group server))
		 (save-window-excursion
		   (set-buffer buffer)
		   (if (> gnus-verbose 6)
		       (pop-to-buffer (current-buffer)))
		   (cd directory)    ; Using relative paths simplifies
					; postprocessing.
		   (let ((group
			  (if (not group)
			      "."
			    ;; Try accessing the group literally as
			    ;; well as interpreting dots as directory
			    ;; separators so the engine works with
			    ;; plain nnml as well as the Gnus Cache.
			    (let ((group (gnus-group-real-name group)))
			      ;; Replace cl-func find-if.
			      (if (file-directory-p group)
				  group
				(if (file-directory-p
				     (setq group
					   (replace-regexp-in-string
					    "\\." "/"
					    group nil t)))
				    group))))))
		     (unless group
		       (error "Cannot locate directory for group"))
		     (save-excursion
		       (apply
			'call-process "find" nil t
			"find" group "-maxdepth" "1" "-type" "f"
			"-name" "[0-9]*" "-exec"
			"grep"
			`("-l" ,@(and grep-options
				      (split-string grep-options "\\s-" t))
			  "-e" ,regexp "{}" "+"))))

		   ;; Translate relative paths to group names.
		   (while (not (eobp))
		     (let* ((path (split-string
				   (buffer-substring
				    (point)
				    (line-end-position)) "/" t))
			    (art (string-to-number (car (last path)))))
		       (while (string= "." (car path))
			 (setq path (cdr path)))
		       (let ((group (mapconcat #'identity
					       ;; Replace cl-func:
					       ;; (subseq path 0 -1)
					       (let ((end (1- (length path)))
						     res)
						 (while
						     (>= (setq end (1- end)) 0)
						   (push (pop path) res))
						 (nreverse res))
					       ".")))
			 (push
			  (vector (gnus-group-full-name group server) art 0)
			  artlist))
		       (forward-line 1)))
		   (message "Searching %s using find-grep...done"
			    (or group server))
		   artlist)))
	     grouplist))))

(declare-function mm-url-insert "mm-url" (url &optional follow-refresh))
(declare-function mm-url-encode-www-form-urlencoded "mm-url" (pairs))

;; gmane interface
(cl-defmethod gnus-search-run-search ((engine gnus-search-gmane)
			       srv query &optional groups)
  "Run a search against a gmane back-end server."
  (let* ((case-fold-search t)
	 (query (plist-get query :query))
	 (groupspec (mapconcat
		     (lambda (x)
		       (if (string-match-p "gmane" x)
			   (format "group:%s" (gnus-group-short-name x))
			 (error "Can't search non-gmane groups: %s" x)))
		     groups " "))
	 (buffer (slot-value engine 'proc-buffer))
	 (search (format "%s %s"
			 (if (listp query)
			     (gnus-search-transform query)
			   query)
			 groupspec))
	 (gnus-inhibit-demon t)
	 artlist)
    (require 'mm-url)
    (with-current-buffer buffer
      (erase-buffer)
      (mm-url-insert
       (concat
	"http://search.gmane.org/nov.php"
	"?"
	(mm-url-encode-www-form-urlencoded
	 `(("query" . ,search)
	   ("HITSPERPAGE" . "999")))))
      (set-buffer-multibyte t)
      (decode-coding-region (point-min) (point-max) 'utf-8)
      (goto-char (point-min))
      (forward-line 1)
      (while (not (eobp))
	(unless (or (eolp) (looking-at "\x0d"))
	  (let ((header (nnheader-parse-nov)))
	    (let ((xref (mail-header-xref header))
		  (xscore (string-to-number (cdr (assoc 'X-Score
							(mail-header-extra header))))))
	      (when (string-match " \\([^:]+\\)[:/]\\([0-9]+\\)" xref)
		(push
		 (vector
		  (gnus-group-prefixed-name (match-string 1 xref) srv)
		  (string-to-number (match-string 2 xref)) xscore)
		 artlist)))))
	(forward-line 1)))
    (apply #'vector (nreverse (delete-dups artlist)))))

(cl-defmethod gnus-search-transform-expression ((_e gnus-search-gmane)
						(_expr (head near)))
  nil)

;; Can Gmane handle OR or NOT keywords?
(cl-defmethod gnus-search-transform-expression ((_e gnus-search-gmane)
						(_expr (head or)))
  nil)

(cl-defmethod gnus-search-transform-expression ((_e gnus-search-gmane)
						(_expr (head not)))
  nil)

(cl-defmethod gnus-search-transform-expression ((_e gnus-search-gmane)
						(expr list))
  "The only keyword value gmane can handle is author, ie from."
  (when (memq (car expr) '(from sender author address))
    (format "author:%s" (cdr expr))))

;;; Util Code:

(defun gnus-search-run-query (specs)
  "Invoke appropriate search engine function."
  ;; For now, run the searches synchronously.  At some point each
  ;; search can be run in its own thread, allowing concurrent searches
  ;; of multiple backends.  At present this causes problems when
  ;; multiple IMAP servers are searched at the same time, apparently
  ;; because the `nntp-server-buffer' variable is getting clobbered,
  ;; or something.  Anyway, that's the reason for the `mapc'.
  (let* ((results [])
	 (q-spec (alist-get 'search-query-spec specs))
	 (query (alist-get 'query q-spec))
	 ;; If the query is already a sexp, just leave it alone.
	 (prepared-query (when (stringp query)
			   (gnus-search-prepare-query q-spec))))
    (mapc
     (lambda (x)
       (let* ((server (car x))
	      (search-engine (gnus-search-server-to-engine server))
	      (groups (cadr x)))
	 ;; Give the search engine a chance to say it wants raw search
	 ;; queries.  If SPECS was passed in with an already-parsed
	 ;; query, that's tough luck for the engine.
	 (setf (alist-get 'query prepared-query)
	       (if (slot-value search-engine 'raw-queries-p)
		   query
		 (alist-get 'query prepared-query)))
	 (setq results
	       (vconcat
		(gnus-search-run-search
		 search-engine server prepared-query groups)
		results))))
     (alist-get 'search-group-spec specs))
    results))

(defun gnus-search-prepare-query (query-spec)
  "Accept a search query in raw format, and return a (possibly)
  parsed version.

QUERY-SPEC is an alist produced by functions such as
`gnus-group-make-search-group', and contains at least a 'query
key, and possibly some meta keys.  This function extracts any
additional meta keys from the query, and optionally parses the
string query into sexp form."
  (let ((q-string (alist-get 'query query-spec))
	key val)
    ;; Look for these meta keys:
    (while (string-match "\\(thread\\|limit\\|raw\\|no-parse\\|count\\):\\([^ ]+\\)" q-string)
      ;; If they're found, push them into the query spec, and remove
      ;; them from the query string.
      (setq key (if (string= (match-string 1 q-string)
			     "raw")
		    ;; "raw" is a synonym for "no-parse".
		    'no-parse
		  (intern (match-string 1 q-string)))
	    val (string-to-number (match-string 2 q-string)))
      (push (cons key
		  ;; A bit stupid, but right now the only possible
		  ;; values are "t", or a number.
		  (if (zerop val) t val))
	    query-spec)
      (setq q-string
	    (string-trim (replace-match "" t t q-string 0))))
    (setf (alist-get 'query query-spec) q-string)
    ;; Decide whether to parse the query or not.
    (setf (alist-get 'query query-spec)
	  (if (and gnus-search-use-parsed-queries
		   (null (alist-get 'no-parse query-spec)))
	      (gnus-search-parse-query q-string)
	    q-string))
    query-spec))

;; This should be done once at Gnus startup time, when the servers are
;; first opened, and the resulting engine instance attached to the
;; server.
(defun gnus-search-server-to-engine (server)
  (let* ((server
	  (or (assoc 'gnus-search-engine
		     (cddr (gnus-server-to-method server)))
	      (assoc (car (gnus-server-to-method server))
		     gnus-search-default-engines)))
	 (inst
	  (cond
	   ((null server) nil)
	   ((eieio-object-p (cadr server))
	    (car server))
	   ((class-p (cadr server))
	    (make-instance (cadr server)))
	   (t nil))))
    (when inst
      (when (cddr server)
	(pcase-dolist (`(,key ,value) (cddr server))
	  (condition-case nil
	      (setf (slot-value inst key) value)
	    ((invalid-slot-name invalid-slot-type)
	     (nnheader-message
	      5 "Invalid search engine parameter: (%s %s)"
	      key value)))))
      inst)))

(autoload 'nnimap-make-thread-query "nnimap")
(declare-function gnus-registry-get-id-key "gnus-registry" (id key))

(defun gnus-search-thread (header)
  "Make an nnselect group based on the thread containing the article
header. The current server will be searched. If the registry is
installed, the server that the registry reports the current
article came from is also searched."
  (let* ((query
	  (list (cons 'query (nnimap-make-thread-query header))))
	 (server
	  (list (list (gnus-method-to-server
	   (gnus-find-method-for-group gnus-newsgroup-name)))))
	 (registry-group (and
			  (bound-and-true-p gnus-registry-enabled)
			  (car (gnus-registry-get-id-key
				(mail-header-id header) 'group))))
	 (registry-server
	  (and registry-group
	       (gnus-method-to-server
		(gnus-find-method-for-group registry-group)))))
    (when registry-server
      (cl-pushnew (list registry-server) server :test #'equal))
    (gnus-group-make-search-group nil (list
				     (cons 'gnus-search-query-spec query)
				     (cons 'gnus-search-group-spec server)))
    (gnus-summary-goto-subject (gnus-id-to-article (mail-header-id header)))))

(defun gnus-search-get-active (srv)
  (let ((method (gnus-server-to-method srv))
	groups)
    (gnus-request-list method)
    (with-current-buffer nntp-server-buffer
      (let ((cur (current-buffer)))
	(goto-char (point-min))
	(unless (or (null gnus-search-ignored-newsgroups)
		    (string= gnus-search-ignored-newsgroups ""))
	  (delete-matching-lines gnus-search-ignored-newsgroups))
	(if (eq (car method) 'nntp)
	    (while (not (eobp))
	      (ignore-errors
		(push (gnus-group-decoded-name
		       (gnus-group-full-name
			(buffer-substring
			 (point)
			 (progn
			   (skip-chars-forward "^ \t")
			   (point)))
			method))
		      groups))
	      (forward-line))
	  (while (not (eobp))
	    (ignore-errors
	      (push (gnus-group-decoded-name
		     (if (eq (char-after) ?\")
			 (gnus-group-full-name (read cur) method)
		       (let ((p (point)) (name ""))
			 (skip-chars-forward "^ \t\\\\")
			 (setq name (buffer-substring p (point)))
			 (while (eq (char-after) ?\\)
			   (setq p (1+ (point)))
			   (forward-char 2)
			   (skip-chars-forward "^ \t\\\\")
			   (setq name (concat name (buffer-substring
						    p (point)))))
			 (gnus-group-full-name name method))))
		    groups))
	    (forward-line)))))
    groups))

(provide 'gnus-search)
;;; gnus-search.el ends here
