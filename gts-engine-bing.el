;;; gts-engine-bing.el --- Microsoft Translate -*- lexical-binding: t -*-

;; Copyright (C) 2021 lorniu <lorniu@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; site: https://cn.bing.cn/translator

;;; Code:

(require 'gts-implements)

(defclass gts-bing-parser (gts-parser) ())

(defclass gts-bing-engine (gts-engine)
  ((tag       :initform "Bing")
   (base-url  :initform "https://www.bing.com")
   (sub-url   :initform "/ttranslatev3")

   (tld-url   :initform nil)
   (ig        :initform nil)
   (key       :initform nil)
   (token     :initform nil)
   (last-time :initform nil)
   (expired-time :initform (* 30 60)) ; todo, test it.

   (ttsk-url  :initform "/tfetspktok")
   (tts-url   :initform "https://%s.tts.speech.microsoft.com/cognitiveservices/v1")
   (tts-tpl   :initform "<speak version='1.0' xml:lang='%s'><voice xml:lang='%s' xml:gender='Female' name='%s'><prosody rate='-20.00%%'>%s</prosody></voice></speak>")

   (parser   :initform (gts-bing-parser))))


;;; Engine

(defvar gts-bing-extra-langs-mapping '(("zh" . "zh-Hans")))

(defvar gts-bing-token-maybe-invalid nil)

(cl-defmethod gts-get-lang ((_ gts-bing-engine) lang)
  (or (cdr-safe (assoc lang gts-bing-extra-langs-mapping)) lang))

(cl-defmethod gts-token-available-p ((o gts-bing-engine))
  (with-slots (token key ig last-time expired-time) o
    (and token key ig last-time
         (not gts-bing-token-maybe-invalid)
         (< (- (time-to-seconds) last-time) expired-time))))

(cl-defmethod gts-with-token ((o gts-bing-engine) callback)
  (with-slots (token key ig base-url) o
    (if (gts-token-available-p o) (funcall callback)
      (gts-do-request (concat base-url "/translator")
                      :done
                      (lambda ()
                        (condition-case err
                            (let (key token ig tld)
                              (goto-char (point-min))
                              (re-search-forward "curUrl=.*/\\([a-z]+\\.bing.com\\)")
                              (setq tld (match-string 1))
                              (re-search-forward "\"ig\":\"\\([^\"]+\\).*params_RichTranslateHelper = \\[\\([0-9]+\\),\"\\([^\"]+\\)")
                              (setq ig (match-string 1) key (match-string 2) token (match-string 3))
                              (oset o ig ig)
                              (oset o key key)
                              (oset o token token)
                              (oset o last-time (time-to-seconds))
                              (oset o tld-url (concat "https://" tld))
                              (setq gts-bing-token-maybe-invalid nil)
                              (gts-do-log 'bing (format "url: %s\nkey: %s\ntoken: %s\nig: %s" tld key token ig))
                              (funcall callback))
                          (error (error "Error occurred when request with bing token (%s, %s)"
                                        (eieio-object-class-name o) err))))
                      :fail
                      (lambda (status)
                        (error (format "ERR: %s" status)))))))

(cl-defmethod gts-translate ((engine gts-bing-engine) &optional text from to rendercb)
  (gts-with-token
   engine
   (lambda ()
     (with-slots (tld-url sub-url token key ig parser) engine
       (gts-do-request (format "%s%s?isVertical=1&IG=%s&IID=translator.5022.1" tld-url sub-url ig)
                       :headers `(("Content-Type" . "application/x-www-form-urlencoded;charset=UTF-8"))
                       :data `(("fromLang" . ,(gts-get-lang engine from))
                               ("to"       . ,(gts-get-lang engine to))
                               ("text"     . ,text)
                               ("key"      . ,key)
                               ("token"    . ,token))
                       :done (lambda ()
                               (let ((result (gts-parse parser text (buffer-string))))
                                 (funcall rendercb result)))
                       :fail (lambda (status)
                               (let ((r (cond ((ignore-errors
                                                 (= (cl-third (car status)) 429))
                                               "[HTTP ERROR]: Too Many Requests! Try later.")
                                              (t status))))
                                 (funcall rendercb r))))))))


;;; TTS

(defvar gts-bing-tts-langs-mapping '(("zh" . ("zh-CN" . "zh-CN-XiaoxiaoNeural"))
                                     ("en" . ("en-US" . "en-US-AriaNeural"))
                                     ("fr" . ("fr-CA" . "fr-CA-SylvieNeural"))
                                     ("de" . ("de-DE" . "de-DE-KatjaNeural"))))

(cl-defmethod gts-tts-payload ((o gts-bing-engine) lang text)
  (with-slots (tts-tpl) o
    (let (l n (mt (assoc lang gts-bing-tts-langs-mapping)))
      (if mt (setq l (cadr mt) n (cddr mt))
        (user-error "Add the mapping of your language into `gts-bing-tts-langs-mapping' :)"))
      (format tts-tpl l l n (encode-coding-string text 'utf-8)))))

(cl-defmethod gts-tts ((engine gts-bing-engine) text lang)
  (gts-with-token
   engine
   (lambda ()
     (with-slots (tld-url sub-url token key ig parser ttsk-url tts-url tts-tpl) engine
       (gts-do-request (format "%s%s?isVertical=1&IG=%s&IID=translator.5022.2" tld-url ttsk-url ig)
                       :headers '(("content-type" . "application/x-www-form-urlencoded"))
                       :data `(("token" . ,token) ("key" . ,key))
                       :done (lambda ()
                               (goto-char url-http-end-of-headers)
                               (let* ((json (json-read))
                                      (token (cdr (assoc 'token json)))
                                      (region (cdr (assoc 'region json))))
                                 (gts-do-log 'bing-tts (format "token: %s\nregion: %s" token region))
                                 (gts-do-request (format tts-url region)
                                                 :data (gts-tts-payload engine lang text)
                                                 :headers `(("content-type" . "application/ssml+xml")
                                                            ("authorization" . ,(format "Bearer %s" token))
                                                            ("x-microsoft-outputformat" . "audio-16khz-32kbitrate-mono-mp3"))
                                                 :done (lambda ()
                                                         (gts-tts-speak-buffer-data))
                                                 :fail (lambda (status)
                                                         (user-error "[BING-TTS] error when play sound")))))
                       :fail (lambda (status)
                               (user-error "%s" status)))))))


;;; Parser

(cl-defmethod gts-parse ((_ gts-bing-parser) _text resp)
  (with-temp-buffer
    (set-buffer-multibyte t)
    (insert resp)
    (goto-char (point-min))
    (re-search-forward "\n\n")
    (delete-region (point-min) (point))
    (decode-coding-region (point-min) (point-max) 'utf-8)
    (goto-char (point-min))
    (gts-do-log 'bing-result (buffer-string))
    (let* ((json (json-read))
           (result (ignore-errors
                     (cdr (assoc 'text
                                 (aref
                                  (cdr (assoc 'translations (aref json 0)))
                                  0))))))
      (or result
          (progn
            (setq gts-bing-token-maybe-invalid t) ; refresh token when error occurred
            (buffer-string))))))


(provide 'gts-engine-bing)

;;; gts-engine-bing.el ends here