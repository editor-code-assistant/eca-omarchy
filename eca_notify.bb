#!/usr/bin/env bb
;; Sends a desktop notification by speaking the D-Bus wire protocol directly
;; over the session bus unix socket — no subprocess is spawned to carry the
;; message, so sensitive content (task questions, approval summaries) never
;; appears in any process's argv (/proc/<pid>/cmdline).
;;
;; Input: one JSON line on stdin:
;;   {"summary": "...", "body": "...", "timeout": 6000}

(ns eca-notify
  (:require [cheshire.core :as json]
            [clojure.string :as str])
  (:import (java.net UnixDomainSocketAddress)
           (java.nio ByteBuffer ByteOrder)
           (java.nio.channels SocketChannel)
           (java.nio.charset StandardCharsets)))

;; ---- inputs (one JSON line on stdin) ----------------------------------------

(def input      (json/parse-string (read-line) true))
(def summary    (or (:summary input) ""))
(def body       (or (:body    input) ""))
(def timeout-ms (int (or (:timeout input) 6000)))

(defn sock-path ^String []
  (-> (or (System/getenv "DBUS_SESSION_BUS_ADDRESS") "")
      (str/replace #"^.*unix:path=" "")
      (str/replace #",.*$" "")))

;; ---- socket I/O -------------------------------------------------------------

(defn write-bytes! [^SocketChannel ch ^bytes bs]
  (let [buf (ByteBuffer/wrap bs)]
    (while (.hasRemaining buf) (.write ch buf))))

(defn write-str! [^SocketChannel ch ^String s]
  (write-bytes! ch (.getBytes s StandardCharsets/UTF_8)))

(defn read-line! [^SocketChannel ch]
  (let [sb (StringBuilder.)
        b1 (ByteBuffer/allocate 1)]
    (loop []
      (.clear b1)
      (.read ch b1)
      (.flip b1)
      (let [c (char (.get b1))]
        (cond
          (= c \newline) (str sb)
          (= c \return)  (recur)
          :else          (do (.append sb c) (recur)))))))

;; ---- D-Bus little-endian wire encoding -------------------------------------

(defn u32 [^long v]
  (let [buf (ByteBuffer/allocate 4)]
    (.order buf ByteOrder/LITTLE_ENDIAN)
    (.putInt buf (unchecked-int v))
    (.array buf)))

(defn dbus-string [^String s]
  ;; STRING: uint32 byte-length + utf8 bytes + NUL
  (let [bs (.getBytes s StandardCharsets/UTF_8)]
    (byte-array (concat (u32 (count bs)) bs [0]))))

(defn dbus-object-path [^String s] (dbus-string s))

(defn dbus-signature [^String s]
  ;; SIGNATURE: uint8 length + bytes + NUL
  (let [bs (.getBytes s StandardCharsets/UTF_8)]
    (byte-array (concat [(count bs)] bs [0]))))

(defn align-pad
  "Zero bytes needed to align `offset` up to `align`."
  [^long offset ^long align]
  (let [r (mod offset align)]
    (byte-array (if (zero? r) 0 (- align r)))))

;; A header field is STRUCT{BYTE, VARIANT{SIGNATURE, value}}, aligned to 8.
(defn hfield [code ^String type-sig ^bytes val]
  (let [raw (byte-array (concat [code] (dbus-signature type-sig) val))]
    (byte-array (concat raw (align-pad (count raw) 8)))))

;; ---- org.freedesktop.Notifications.Notify body ------------------------------
;;
;; Signature: susssasa{sv}i
;;   app_name(s) replaces_id(u) app_icon(s) summary(s) body(s)
;;   actions(as) hints(a{sv}) expire_timeout(i)

(defn build-body ^bytes [^String summary ^String body ^long timeout-ms]
  (byte-array
    (concat
      (dbus-string  "ECA")      ; app_name
      (u32          0)          ; replaces_id
      (dbus-string  "")         ; app_icon
      (dbus-string  summary)    ; summary
      (dbus-string  body)       ; body
      (u32          0)          ; actions  – empty array<string> (0 content bytes)
      (u32          0)          ; hints    – empty array<dict-entry> (0 content bytes)
      (u32          timeout-ms)))) ; expire_timeout (int32, reuse u32 for LE encoding)

;; ---- Assemble the full D-Bus message ----------------------------------------

(defn build-msg ^bytes [^String summary ^String body ^long timeout-ms]
  (let [f-path  (hfield 1 "o" (dbus-object-path "/org/freedesktop/Notifications"))
        f-iface (hfield 2 "s" (dbus-string      "org.freedesktop.Notifications"))
        f-mem   (hfield 3 "s" (dbus-string      "Notify"))
        f-dest  (hfield 6 "s" (dbus-string      "org.freedesktop.Notifications"))
        f-sig   (hfield 8 "g" (dbus-signature   "susssasa{sv}i"))

        hf-content  (byte-array (concat f-path f-iface f-mem f-dest f-sig))
        body-bytes  (build-body summary body timeout-ms)

        ;; Fixed 12-byte header: endian(1) type(1) flags(1) proto(1) body-len(4) serial(4)
        fixed-hdr (byte-array (concat [(int \l) 1 0 1]
                                      (u32 (count body-bytes))
                                      (u32 1)))
        hf-array  (byte-array (concat (u32 (count hf-content)) hf-content))
        full-hdr  (byte-array (concat fixed-hdr hf-array))
        hdr-pad   (align-pad (count full-hdr) 8)]
    (byte-array (concat full-hdr hdr-pad body-bytes))))

;; ---- SASL EXTERNAL auth + send ----------------------------------------------

(defn hex-of-uid ^String []
  ;; D-Bus EXTERNAL auth data is the uid decimal string hex-encoded as ASCII.
  ;; e.g. uid=1000 -> "1000" -> bytes [0x31 0x30 0x30 0x30] -> "31303030"
  (let [uid (.trim (slurp (.getInputStream (-> (ProcessBuilder. ["id" "-u"]) .start))))]
    (apply str (map #(format "%02x" %) (.getBytes uid "UTF-8")))))

(let [addr (UnixDomainSocketAddress/of (sock-path))
      ch   (SocketChannel/open addr)]
  ;; D-Bus unix socket handshake: leading NUL byte, then SASL
  (write-bytes! ch (byte-array [0]))
  (write-str!   ch (str "AUTH EXTERNAL " (hex-of-uid) "\r\n"))
  (let [r1 (read-line! ch)]
    (when-not (str/starts-with? r1 "OK ")
      (binding [*out* *err*] (println "eca-notify: D-Bus auth failed:" r1))
      (System/exit 1)))
  (write-str! ch "NEGOTIATE_UNIX_FD\r\n")
  (read-line! ch)                        ; consume AGREE_UNIX_FD
  (write-str! ch "BEGIN\r\n")
  (write-bytes! ch (build-msg summary body timeout-ms))
  (.close ch))
