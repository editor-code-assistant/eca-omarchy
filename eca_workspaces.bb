#!/usr/bin/env bb
;; Lists folders the ECA widget can open a session in, as JSON:
;;
;;   {"workspaces":[{"path","name","chatCount","updatedAt","lastTitle"}...]}
;;
;; 1. Workspaces ECA already has chat history for. Each cache dir
;;    ($XDG_CACHE_HOME/eca/<name>_<hash>/) is mapped back to its folder by
;;    hashing candidate folders the way ECA does (eca.cache/paths-hash: first
;;    8 chars of the URL-safe, unpadded base64 SHA-256 of the sorted paths
;;    joined with ":"). Chat counts come from `eca read-chat`.
;; 2. Git repositories under the usual project roots, so new projects can be
;;    picked too.
;;
;; Usage: eca_workspaces.bb [--roots DIR:DIR] [--eca-bin PATH]
(ns eca-workspaces
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str])
  (:import (java.security MessageDigest)
           (java.util Base64)))

(def home (System/getProperty "user.home"))

(defn parse-args [args]
  (loop [m {} [a b & more :as xs] args]
    (cond
      (empty? xs) m
      (and (str/starts-with? a "--") b) (recur (assoc m (keyword (subs a 2)) b) more)
      :else (recur m (rest xs)))))

(def opts (parse-args *command-line-args*))

(defn expand [s] (str/replace (str/trim (str s)) #"^~(?=/|$)" home))

(def cache-root
  (fs/path (or (not-empty (System/getenv "XDG_CACHE_HOME")) (str home "/.cache")) "eca"))

;; ---- ECA's cache key -------------------------------------------------------

(defn paths-hash [paths]
  (let [digest (.digest (MessageDigest/getInstance "SHA-256")
                        (.getBytes ^String (str/join ":" (sort paths)) "UTF-8"))]
    (subs (.encodeToString (.withoutPadding (Base64/getUrlEncoder)) digest) 0 8)))

(defn sanitize-name [n]
  (let [s (str/replace (str n) #"[^a-zA-Z0-9._-]" "_")]
    (subs s 0 (min 30 (count s)))))

;; ---- eca binary ------------------------------------------------------------

(defn executable? [f] (and f (fs/regular-file? f) (fs/executable? f)))

(defn running-eca-exes []
  (->> (fs/list-dir "/proc")
       (keep (fn [d]
               (when (re-matches #"\d+" (fs/file-name d))
                 (let [argv (try (str/split (slurp (str d "/cmdline")) #"\u0000") (catch Exception _ nil))]
                   (when (and argv (= "eca" (fs/file-name (first argv))) (= "server" (second argv)))
                     (try (str/replace (str (fs/read-link (str d "/exe"))) #" \(deleted\)$" "")
                          (catch Exception _ nil)))))))))

(defn find-eca []
  (let [configured (some-> (:eca-bin opts) not-empty expand)]
    (or (when (executable? configured) configured)
        (some-> (fs/which "eca") str)
        (first (filter executable? (running-eca-exes)))
        (->> [".emacs.d/eca/eca" ".config/emacs/eca/eca"
              ".local/share/nvim/eca/eca" ".local/bin/eca"]
             (map #(str home "/" %))
             (filter executable?)
             first))))

(defn run [cmd timeout-ms]
  (let [proc (p/process cmd {:out :string :err :string})
        res (deref proc timeout-ms ::timeout)]
    (if (= res ::timeout)
      (do (p/destroy-tree proc) {:exit -1 :out ""})
      res)))

;; ---- folders ---------------------------------------------------------------

(defn subdirs [dir]
  (try
    (->> (fs/list-dir dir)
         (filter #(and (fs/directory? %) (not (str/starts-with? (fs/file-name %) ".")))))
    (catch Exception _ [])))

(defn walk [root depth]
  (when (fs/directory? root)
    (loop [frontier [(fs/path root)] acc [(fs/path root)] d depth]
      (if (or (zero? d) (empty? frontier))
        acc
        (let [next (mapcat subdirs frontier)]
          (recur next (into acc next) (dec d)))))))

(def project-roots
  (concat (map #(str home "/" %) ["Work" "Projects" "projects" "src" "code" "dev" "git"])
          (some->> (:roots opts) (#(str/split % #":")) (remove str/blank?) (map expand))))

(defn candidate-dirs []
  (distinct
   (concat
    (mapcat #(walk % 3) project-roots)
    (walk (str home "/.config/omarchy/plugins") 1)
    (walk (str home "/.config") 1)
    (walk home 1))))

(defn git-repos []
  (->> project-roots
       (mapcat #(walk % 2))
       (filter #(fs/exists? (fs/path % ".git")))
       (map #(str (fs/absolutize %)))
       distinct))

(defn cache-dirs []
  (if (fs/directory? cache-root)
    (->> (fs/list-dir cache-root)
         (filter #(fs/directory? (fs/path % "chats")))
         (keep (fn [d]
                 (when-let [[_ prefix hash] (re-matches #"(.*)_([A-Za-z0-9_-]{8})" (fs/file-name d))]
                   {:dir (str d) :prefix prefix :hash hash}))))
    []))

(defn resolve-paths [dirs]
  (let [wanted (set (map :prefix dirs))
        by-hash (->> (candidate-dirs)
                     (filter #(contains? wanted (sanitize-name (fs/file-name %))))
                     (map #(str (fs/absolutize %)))
                     (reduce (fn [m p] (assoc m (paths-hash [p]) p)) {}))]
    (keep #(when-let [path (get by-hash (:hash %))] (assoc % :path path)) dirs)))

(defn history [eca dir]
  (if-not eca
    {:chatCount 0}
    (let [{:keys [exit out]} (run [eca "read-chat" "--db-cache-path" dir] 15000)
          chats (when (zero? exit)
                  (->> (str/split-lines out)
                       (keep #(try (json/parse-string % true) (catch Exception _ nil)))
                       (filter :id)
                       (sort-by #(or (:updated-at %) (:created-at %) 0) >)))]
      {:chatCount (count chats)
       :updatedAt (some #(or (:updated-at %) (:created-at %)) chats)
       :lastTitle (some :title chats)})))

(defn -main []
  (let [eca (find-eca)
        with-history (->> (resolve-paths (cache-dirs))
                          (pmap (fn [{:keys [dir path]}]
                                  (merge {:path path :name (fs/file-name path)} (history eca dir))))
                          (filter #(pos? (:chatCount %)))
                          (sort-by #(or (:updatedAt %) 0) >)
                          vec)
        known (set (map :path with-history))
        repos (->> (git-repos)
                   (remove known)
                   (sort-by #(str/lower-case (fs/file-name %)))
                   (map (fn [p] {:path p :name (fs/file-name p) :chatCount 0})))]
    {:ecaBinary eca
     :workspaces (vec (concat with-history repos))}))

;; Run as a script (bb eca_workspaces.bb), but not when loaded as a library
;; by the test suite via (load-file ...).
(when (= *file* (System/getProperty "babashka.file"))
  (println (json/generate-string
            (try (-main)
                 (catch Exception e {:workspaces [] :error (str "eca-workspaces: " (ex-message e))}))))
  (shutdown-agents))
