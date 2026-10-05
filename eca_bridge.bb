#!/usr/bin/env bb
;; stdio bridge between the Omarchy shell and an `eca server`.
;;
;; ECA speaks JSON-RPC 2.0 with LSP-style `Content-Length` framing
;; (https://eca.dev/protocol/). Quickshell's Process can only split stdout on a
;; marker, so this bridge translates:
;;
;;   stdin  : one JSON-RPC message per line  ->  framed messages to eca server
;;   stdout : framed messages from the server ->  one compact JSON per line
;;
;; Extra lines the bridge itself emits carry a "bridge" key instead of
;; "jsonrpc": {"bridge":"started",...}, {"bridge":"exited","code":N},
;; {"bridge":"error","message":...}.
;;
;; `initialize` requests get `processId` set to this bridge's pid, so the server
;; exits on its own if the bridge dies. When stdin closes (the shell went away
;; or the session was stopped) the bridge sends shutdown + exit and reaps the
;; server.
;;
;; Usage: eca_bridge.bb --workspace DIR [--eca PATH] [--log-level LEVEL] [--config-file FILE]
(ns eca-bridge
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str])
  (:import (java.io BufferedReader InputStream InputStreamReader OutputStream PrintStream)
           (java.nio.charset StandardCharsets)))

(def home (System/getProperty "user.home"))

(defn parse-args [args]
  (loop [m {} [a b & more :as xs] args]
    (cond
      (empty? xs) m
      (and (str/starts-with? a "--") b) (recur (assoc m (keyword (subs a 2)) b) more)
      :else (recur m (rest xs)))))

(def opts (parse-args *command-line-args*))

(def out (PrintStream. System/out true "UTF-8"))
(def out-lock (Object.))

(defn emit! [m]
  (let [line (json/generate-string m)]
    (locking out-lock
      (.println out line)
      (.flush out))))

(defn executable? [f] (and f (fs/regular-file? f) (fs/executable? f)))

(defn find-eca []
  (let [configured (some-> (:eca opts) str/trim not-empty (str/replace #"^~(?=/|$)" home))]
    (or (when (executable? configured) configured)
        (some-> (fs/which "eca") str)
        (->> [".emacs.d/eca/eca" ".config/emacs/eca/eca"
              ".local/share/nvim/eca/eca" ".local/bin/eca" ".cache/eca/bin/eca"]
             (map #(str home "/" %))
             (filter executable?)
             first))))

;; ---- framing ---------------------------------------------------------------

(defn read-headers
  "Reads header lines up to the blank line. Returns a map of lower-cased
  header names, or nil on EOF."
  [^InputStream in]
  (loop [headers {} line (StringBuilder.)]
    (let [b (.read in)]
      (cond
        (neg? b) nil
        (= b 10) (let [l (str/trimr (str line))]
                   (if (str/blank? l)
                     (if (seq headers) headers (recur headers (StringBuilder.)))
                     (let [[k v] (str/split l #":\s*" 2)]
                       (recur (assoc headers (str/lower-case k) v) (StringBuilder.)))))
        :else (recur headers (doto line (.append (char b))))))))

(defn read-message [^InputStream in]
  (when-let [headers (read-headers in)]
    (let [n (parse-long (str/trim (get headers "content-length" "0")))
          bytes (.readNBytes in (int n))]
      (when (= n (alength bytes))
        (String. bytes StandardCharsets/UTF_8)))))

(defn write-message! [^OutputStream os ^String body]
  (let [bytes (.getBytes body StandardCharsets/UTF_8)
        header (.getBytes (str "Content-Length: " (alength bytes) "\r\n\r\n") StandardCharsets/US_ASCII)]
    (locking os
      (.write os header)
      (.write os bytes)
      (.flush os))))

;; ---- main ------------------------------------------------------------------

(defn log-file []
  (let [dir (fs/path (or (System/getenv "XDG_CACHE_HOME") (str home "/.cache")) "omarchy-eca")]
    (fs/create-dirs dir)
    (str (fs/path dir "server.log"))))

(defn -main []
  (let [workspace (some-> (:workspace opts) (str/replace #"^~(?=/|$)" home))
        eca (find-eca)]
    (cond
      (not (and workspace (fs/directory? workspace)))
      (do (emit! {:bridge "error" :message (str "Workspace folder not found: " workspace)})
          (System/exit 2))

      (nil? eca)
      (do (emit! {:bridge "error" :message "Could not find the eca binary. The plugin should have downloaded it automatically — check ~/.cache/omarchy-eca/setup.log, or set a custom path in the widget settings."})
          (System/exit 3))

      :else
      (let [log (log-file)
            cmd (cond-> [eca "server" "--log-level" (or (:log-level opts) "info")]
                  (:config-file opts) (conj "--config-file" (:config-file opts)))
            _ (spit log (str "\n[" (java.time.Instant/now) "] " (str/join " " cmd) " in " workspace "\n") :append true)
            server (p/process cmd {:dir workspace :err :append :err-file (fs/file log)})
            server-in ^OutputStream (:in server)
            server-out ^InputStream (:out server)
            my-pid (.pid (java.lang.ProcessHandle/current))
            shutting-down (atom false)]
        (emit! {:bridge "started" :pid my-pid :serverPid (.pid ^Process (:proc server))
                :eca eca :workspace (str (fs/absolutize workspace)) :log log})

        ;; server -> shell
        (future
          (try
            (loop []
              (when-let [body (read-message server-out)]
                (try
                  (emit! (json/parse-string body))
                  (catch Exception e
                    (emit! {:bridge "error" :message (str "Bad message from server: " (ex-message e))})))
                (recur)))
            (catch Exception e
              (when-not @shutting-down
                (emit! {:bridge "error" :message (str "Server stream failed: " (ex-message e))}))))
          (let [code (:exit @server)]
            (emit! {:bridge "exited" :code code})
            (System/exit 0)))

        ;; shell -> server
        (let [rdr (BufferedReader. (InputStreamReader. System/in StandardCharsets/UTF_8))]
          (loop []
            (when-let [line (.readLine rdr)]
              (when-not (str/blank? line)
                (try
                  (let [msg (json/parse-string line)
                        msg (if (= "initialize" (get msg "method"))
                              (assoc-in msg ["params" "processId"] my-pid)
                              msg)]
                    (write-message! server-in (json/generate-string msg)))
                  (catch Exception e
                    (emit! {:bridge "error" :message (str "Bad message from client: " (ex-message e))}))))
              (recur))))

        ;; stdin closed: shut the server down politely, then make sure.
        (reset! shutting-down true)
        (try
          (write-message! server-in (json/generate-string {:jsonrpc "2.0" :id "bridge-shutdown" :method "shutdown"}))
          (Thread/sleep 300)
          (write-message! server-in (json/generate-string {:jsonrpc "2.0" :method "exit"}))
          (catch Exception _ nil))
        (when (= ::timeout (deref server 4000 ::timeout))
          (p/destroy-tree server))
        (System/exit 0)))))

;; Run as a script (bb eca_bridge.bb), but not when loaded as a library
;; by the test suite via (load-file ...).
(when (= *file* (System/getProperty "babashka.file"))
  (-main))
