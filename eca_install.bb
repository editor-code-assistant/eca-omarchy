#!/usr/bin/env bb
;; Keeps the bundled eca server binary (bin/eca, next to this script) up to
;; date with the latest GitHub release.
;;
;; The initial binary is committed to the repo by the CI release workflow, so
;; `omarchy plugin add` delivers a working eca without any network access.
;; This script runs in the background on every shell start to check for and
;; apply updates to that bundled binary.
;;
;; A stamp file prevents hammering the GitHub API; the check is skipped when
;; the stamp is < 24h old and the version is current.  Failed updates never
;; write the stamp, so they retry on next startup.
;;
;; Output — single JSON line:
;;   {"status":"up-to-date"|"updated"|"failed"|"skipped",
;;    "current":"0.161.2", "latest":"0.162.0",
;;    "path":"/path/to/plugin/bin/eca",
;;    "error":"…"}
;;
;; Usage: bb eca_install.bb [--force]   (--force bypasses the 24h stamp)
(ns eca-install
  (:require [babashka.fs :as fs]
            [babashka.http-client :as http]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str]))

(def home       (System/getProperty "user.home"))
;; Derive the plugin dir from this script's own location.
(def plugin-dir (str (fs/parent (fs/absolutize *file*))))
;; The bundled binary lives alongside this script in bin/.
(def bin-dir    (str (fs/path plugin-dir "bin")))
(def bin-eca    (str (fs/path bin-dir "eca")))

(def cache-dir  (str (fs/path (or (System/getenv "XDG_CACHE_HOME") (str home "/.cache")) "omarchy-eca")))
(def log-file   (str (fs/path cache-dir "install.log")))
(def stamp      (str (fs/path cache-dir "last-eca-check")))
(def tmp-zip    (str (fs/path cache-dir "eca-download.zip")))
(def tmp-dir    (str (fs/path cache-dir "eca-extract")))

(def force? (some #{"--force"} *command-line-args*))

;; ---- logging ---------------------------------------------------------------

(defn log! [& parts]
  (let [msg (str "[" (java.time.Instant/now) "] " (str/join " " parts) "\n")]
    (fs/create-dirs cache-dir)
    (spit log-file msg :append true)))

;; ---- platform --------------------------------------------------------------

(defn arch []
  (str/trim (:out @(p/process ["uname" "-m"] {:out :string :err :string}))))

(defn platform []
  (case (arch)
    "x86_64"  "static-linux-amd64"
    "aarch64" "linux-aarch64"
    nil))

;; ---- version helpers -------------------------------------------------------

(defn parse-semver [s]
  (when-let [m (re-find #"(\d+)\.(\d+)\.(\d+)" (str s))]
    (mapv parse-long (rest m))))

(defn semver> [a b]
  (let [av (parse-semver a) bv (parse-semver b)]
    (and av bv (pos? (compare av bv)))))

;; ---- binary checks ---------------------------------------------------------

(defn executable? [f]
  (and f (fs/regular-file? f) (fs/executable? f)))

(defn current-version []
  ;; Reads the version of the bundled bin/eca.  Returns nil when not present,
  ;; not executable, or wrong architecture (e.g. x86_64 binary on aarch64).
  (when (executable? bin-eca)
    (try
      (let [r @(p/process [bin-eca "--version"] {:out :string :err :string})]
        (when (zero? (:exit r))
          (re-find #"\d+\.\d+\.\d+" (:out r))))
      (catch Exception _ nil))))

;; ---- GitHub releases API ---------------------------------------------------

(def releases-api
  "https://api.github.com/repos/editor-code-assistant/eca/releases/latest")

(defn fetch-latest-tag []
  (try
    (let [resp (http/get releases-api
                         {:headers {"Accept"     "application/vnd.github.v3+json"
                                    "User-Agent" "omarchy-eca-plugin"}
                          :throw false :timeout 15000})]
      (when (= 200 (:status resp))
        (:tag_name (json/parse-string (:body resp) true))))
    (catch Exception e
      (log! "fetch-latest-tag failed:" (ex-message e))
      nil)))

;; ---- stamp -----------------------------------------------------------------

(defn stamp-fresh? [current latest]
  (and (not force?)
       (fs/exists? stamp)
       (= current latest)
       (let [age-ms (- (System/currentTimeMillis) (.lastModified (fs/file stamp)))]
         (< age-ms (* 24 3600 1000)))))

(defn touch-stamp! []
  (fs/create-dirs cache-dir)
  (spit stamp ""))

;; ---- download and install --------------------------------------------------

(defn download-url [tag]
  (when-let [plat (platform)]
    (str "https://github.com/editor-code-assistant/eca/releases/download/"
         tag "/eca-native-" plat ".zip")))

(defn download! [url dest]
  ;; Prefer curl — streams directly to disk, handles redirects, clear errors.
  (log! "Downloading" url)
  (if (fs/which "curl")
    (let [r @(p/process ["curl" "-fL" "--silent" "--show-error"
                          "--connect-timeout" "30" "--max-time" "300"
                          "--output" dest url]
                        {:out :string :err :string})]
      (when-not (zero? (:exit r))
        (throw (ex-info (str "curl failed: " (str/trim (:err r))) {}))))
    ;; Fallback: babashka.http-client
    (let [resp (http/get url {:as :bytes :throw false :timeout 300000})]
      (when-not (= 200 (:status resp))
        (throw (ex-info (str "Download failed HTTP " (:status resp)) {})))
      (java.nio.file.Files/write
       (java.nio.file.Paths/get dest (into-array String []))
       ^bytes (:body resp)
       (into-array java.nio.file.StandardOpenOption
                   [java.nio.file.StandardOpenOption/CREATE
                    java.nio.file.StandardOpenOption/TRUNCATE_EXISTING]))))
  (let [size (if (fs/exists? dest) (fs/size dest) 0)]
    (when (< size 1000000)
      (throw (ex-info (str "Downloaded file too small (" size " bytes)") {})))))

(defn extract! [zip-path dest-dir]
  (fs/delete-tree dest-dir)
  (fs/create-dirs dest-dir)
  (let [r @(p/process ["unzip" "-qq" "-o" zip-path "-d" dest-dir]
                      {:out :string :err :string})]
    (when-not (zero? (:exit r))
      (throw (ex-info (str "unzip failed: " (str/trim (:err r))) {})))))

(defn update-binary! [tag]
  (let [url (or (download-url tag) (throw (ex-info (str "Unsupported platform: " (arch)) {})))]
    (fs/create-dirs bin-dir)
    ;; Download
    (download! url tmp-zip)
    ;; Extract (zip root contains just `eca`)
    (extract! tmp-zip tmp-dir)
    (let [extracted (or (some #(when (= "eca" (fs/file-name %)) (str %))
                              (file-seq (fs/file tmp-dir)))
                        (throw (ex-info "eca binary not found in zip" {})))]
      ;; Atomically replace: write to a temp path then rename
      (let [tmp-bin (str bin-eca ".new")]
        (fs/copy extracted tmp-bin {:replace-existing true})
        (fs/set-posix-file-permissions tmp-bin "rwxr-xr-x")
        ;; Verify before replacing
        (let [r @(p/process [tmp-bin "--version"] {:out :string :err :string})]
          (when-not (zero? (:exit r))
            (fs/delete-if-exists tmp-bin)
            (throw (ex-info "Downloaded binary failed version check" {}))))
        (fs/move tmp-bin bin-eca {:replace-existing true})))
    ;; Cleanup
    (fs/delete-if-exists tmp-zip)
    (fs/delete-tree tmp-dir)
    (log! "Updated bin/eca to" tag)))

;; ---- main ------------------------------------------------------------------

(defn -main []
  (fs/create-dirs cache-dir)
  (let [current (current-version)]
    (log! "eca_install.bb" (if force? "--force" "") "current=" (or current "none") "bin=" bin-eca)
    (let [latest (fetch-latest-tag)]
      (log! "latest=" (or latest "unavailable"))
      (cond
        (nil? latest)
        {:status "skipped" :current current :path bin-eca
         :error "GitHub API unreachable — will retry next startup"}

        (stamp-fresh? current latest)
        {:status "skipped" :current current :latest latest :path bin-eca}

        (and current (not (semver> latest current)))
        (do (touch-stamp!)
            {:status "up-to-date" :current current :latest latest :path bin-eca})

        :else
        (try
          (update-binary! latest)
          (touch-stamp!)
          {:status  (if current "updated" "installed")
           :current latest :latest latest :path bin-eca}
          (catch Exception e
            (log! "Update failed:" (ex-message e))
            ;; Don't write stamp — retry on next startup.
            {:status "failed" :current current :latest latest
             :error (ex-message e)}))))))

(when (= *file* (System/getProperty "babashka.file"))
  (println (json/generate-string
            (try (-main)
                 (catch Exception e
                   (log! "Fatal:" (ex-message e))
                   {:status "failed" :error (or (ex-message e) (str e))}))))
  (shutdown-agents))
