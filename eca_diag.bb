#!/usr/bin/env bb
;; Diagnostic script for the omarchy-eca plugin.
;; Run this on a machine where the plugin isn't working to get a full report.
;;
;;   bb ~/.config/omarchy/plugins/eca/eca_diag.bb
;;
;; Prints a human-readable report to stdout and exits 0.
(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def home (System/getProperty "user.home"))

(defn section [title] (println) (println (str "── " title " " (apply str (repeat (- 60 (count title)) "─")))))
(defn ok   [msg] (println (str "  ✓  " msg)))
(defn warn [msg] (println (str "  ⚠  " msg)))
(defn fail [msg] (println (str "  ✗  " msg)))
(defn info [msg] (println (str "     " msg)))

(defn run [& cmd]
  (let [r @(p/process (vec cmd) {:out :string :err :string :continue true})]
    {:exit (:exit r) :out (str/trim (:out r)) :err (str/trim (:err r))}))

(defn check-cmd [cmd]
  (some-> (fs/which cmd) str))

;; ── bb ──────────────────────────────────────────────────────────────────────
(section "Babashka (bb)")
(let [bb (check-cmd "bb")]
  (if bb
    (do (ok (str "bb found at " bb))
        (info (:out (run "bb" "--version"))))
    (fail "bb not found on PATH — the plugin cannot function without it")))

;; ── eca binary ──────────────────────────────────────────────────────────────
(section "eca binary")
(let [candidates [".local/bin/eca" ".emacs.d/eca/eca" ".config/emacs/eca/eca"
                  "em/eca/eca" ".local/share/nvim/eca/eca" ".cache/eca/bin/eca"]
      found (->> candidates
                 (map #(str home "/" %))
                 (filter #(and (fs/exists? %) (fs/executable? %)))
                 first)
      on-path (check-cmd "eca")]
  (if (or found on-path)
    (let [eca (or on-path found)
          v   (:out (run eca "--version"))]
      (ok (str "eca found at " eca))
      (info (str "version: " v))
      (when (not (fs/executable? eca))
        (fail (str eca " exists but is NOT executable"))))
    (do
      (fail "eca binary not found in any standard location")
      (info "Expected locations:")
      (doseq [c candidates] (info (str "  " home "/" c))))))

;; ── plugin files ────────────────────────────────────────────────────────────
(section "Plugin files")
(let [plugin-dir (str home "/.config/omarchy/plugins/eca")]
  (info (str "Plugin dir: " plugin-dir))
  (if (fs/directory? plugin-dir)
    (do
      (ok "Plugin directory exists")
      (when (java.nio.file.Files/isSymbolicLink (java.nio.file.Paths/get plugin-dir (into-array String [])))
        (info (str "  → symlink to " (fs/read-link plugin-dir))))
      (doseq [f ["manifest.json" "Service.qml" "Session.qml"
                 "eca_bridge.bb" "eca_workspaces.bb" "eca_install.bb"]]
        (let [path (str plugin-dir "/" f)]
          (if (fs/exists? path)
            (ok f)
            (fail (str f " is MISSING"))))))
    (fail (str plugin-dir " does not exist — plugin not installed"))))

;; ── bin/bb in plugin ────────────────────────────────────────────────────────
(section "Bundled bb (bin/bb)")
(let [bundled (str home "/.config/omarchy/plugins/eca/bin/bb")]
  (if (fs/exists? bundled)
    (if (fs/executable? bundled)
      (do (ok (str "bin/bb present and executable"))
          (info (:out (run bundled "--version"))))
      (fail "bin/bb exists but is NOT executable"))
    (warn "bin/bb not present — plugin will use system bb (that's fine if bb is on PATH)")))

;; ── install log ─────────────────────────────────────────────────────────────
(section "Install log (~/.cache/omarchy-eca/install.log)")
(let [cache (str home "/.cache/omarchy-eca")
      log   (str cache "/install.log")
      stamp (str cache "/last-version-check")]
  (if (fs/exists? log)
    (do
      (ok (str "install.log found — last 20 lines:"))
      (doseq [line (take-last 20 (str/split-lines (slurp log)))]
        (info line)))
    (warn "No install.log yet — eca_install.bb has not run or logged nothing"))
  (if (fs/exists? stamp)
    (let [age-h (/ (- (System/currentTimeMillis) (.lastModified (fs/file stamp))) 3600000.0)]
      (info (str "Version check stamp: " (format "%.1f" age-h) "h old")))
    (info "No version check stamp — next startup will check GitHub")))

;; ── server log ──────────────────────────────────────────────────────────────
(section "Server log (~/.cache/omarchy-eca/server.log)")
(let [log (str home "/.cache/omarchy-eca/server.log")]
  (if (fs/exists? log)
    (do
      (ok "server.log found — last 30 lines:")
      (doseq [line (take-last 30 (str/split-lines (slurp log)))]
        (info line)))
    (warn "No server.log yet — eca server has not started")))

;; ── bridge smoke test ───────────────────────────────────────────────────────
(section "Bridge smoke test")
(let [plugin-dir (str home "/.config/omarchy/plugins/eca")
      bridge     (str plugin-dir "/eca_bridge.bb")
      bb-bin     (let [b (str plugin-dir "/bin/bb")]
                   (if (and (fs/exists? b) (fs/executable? b)) b "bb"))]
  (if (fs/exists? bridge)
    (do
      (info (str "Running: " bb-bin " " bridge " --workspace /tmp"))
      (let [{:keys [out]} @(p/process [bb-bin bridge "--workspace" "/tmp"]
                                      {:out :string :err :string :in ""})]
        (let [first-line (first (filter (complement str/blank?) (str/split-lines out)))]
          (if first-line
            (do
              (ok (str "Bridge responded: " first-line))
              (when (str/includes? first-line "\"error\"")
                (fail "Bridge reported an error — see above")))
            (fail "Bridge produced no output")))))
    (fail (str "eca_bridge.bb not found at " bridge))))

;; ── IPC status ──────────────────────────────────────────────────────────────
(section "IPC status (omarchy-shell eca status)")
(let [{:keys [exit out err]} (run "omarchy-shell" "eca" "status")]
  (if (zero? exit)
    (do (ok "IPC responded") (info out))
    (warn (str "IPC failed (is the shell running?): " err))))

(println)
(println "── Done ─────────────────────────────────────────────────────────────────────")
(println "  Share the output above to diagnose the issue.")
(println "  Full logs: ~/.cache/omarchy-eca/install.log  and  server.log")
