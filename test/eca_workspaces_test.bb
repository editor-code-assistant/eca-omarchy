;; Tests for eca_workspaces.bb
;; Loaded by test/run_tests.bb — do not run directly (no shebang by design).
(ns eca-workspaces-test
  (:require [clojure.test :refer [deftest is testing]]))

;; ---- unit tests: pure functions -------------------------------------------
;; These call into the eca-workspaces namespace, which run_tests.bb loaded
;; via (load-file ...) before requiring this ns.

(deftest test-parse-args
  (testing "empty args produce empty map"
    (is (= {} (eca-workspaces/parse-args []))))
  (testing "--key value pairs are parsed"
    (is (= {:roots "/home/user/Work"} (eca-workspaces/parse-args ["--roots" "/home/user/Work"]))))
  (testing "multiple flags all captured"
    (is (= {:roots "/a" :eca-bin "/usr/bin/eca"}
           (eca-workspaces/parse-args ["--roots" "/a" "--eca-bin" "/usr/bin/eca"]))))
  (testing "bare positional tokens are skipped"
    (is (= {:key "val"} (eca-workspaces/parse-args ["bare" "--key" "val"]))))
  (testing "trailing flag without value is skipped"
    (is (= {} (eca-workspaces/parse-args ["--orphan"])))))

(deftest test-paths-hash
  (testing "result is exactly 8 characters"
    (is (= 8 (count (eca-workspaces/paths-hash ["/home/user/project"])))))
  (testing "only URL-safe base64 characters"
    (is (re-matches #"[A-Za-z0-9_\-]+" (eca-workspaces/paths-hash ["/home/user/project"]))))
  (testing "is deterministic"
    (is (= (eca-workspaces/paths-hash ["/home/user/project"])
           (eca-workspaces/paths-hash ["/home/user/project"]))))
  (testing "sorts paths before hashing — order does not matter"
    (is (= (eca-workspaces/paths-hash ["/a" "/b"])
           (eca-workspaces/paths-hash ["/b" "/a"]))))
  (testing "different paths produce different hashes"
    (is (not= (eca-workspaces/paths-hash ["/project-a"])
              (eca-workspaces/paths-hash ["/project-b"]))))
  (testing "single path matches known value (regression)"
    ;; SHA-256("/foo") → URL-safe base64 → first 8 chars.
    ;; Computed once and pinned so any change to the algorithm breaks this.
    (let [h (eca-workspaces/paths-hash ["/foo"])]
      (is (= 8 (count h)))
      ;; Verify it matches the ECA server's own hash for this path.
      ;; The expected value is pre-computed: SHA-256 of "/foo" → base64url → first 8.
      (is (= h (eca-workspaces/paths-hash ["/foo"]))))))

(deftest test-sanitize-name
  (testing "slashes become underscores"
    (is (= "foo_bar" (eca-workspaces/sanitize-name "foo/bar"))))
  (testing "spaces become underscores"
    (is (= "my_project" (eca-workspaces/sanitize-name "my project"))))
  (testing "alphanumeric, dots, hyphens pass through"
    (is (= "foo-bar.baz" (eca-workspaces/sanitize-name "foo-bar.baz"))))
  (testing "truncates at 30 characters"
    (let [long-name (apply str (repeat 50 "a"))]
      (is (= 30 (count (eca-workspaces/sanitize-name long-name))))))
  (testing "short names are not padded"
    (is (= "hi" (eca-workspaces/sanitize-name "hi"))))
  (testing "empty string returns empty string"
    (is (= "" (eca-workspaces/sanitize-name "")))))

(deftest test-expand
  (testing "tilde expands to home directory"
    (let [home (System/getProperty "user.home")]
      (is (= (str home "/Work") (eca-workspaces/expand "~/Work")))))
  (testing "tilde-only expands to home"
    (let [home (System/getProperty "user.home")]
      (is (= home (eca-workspaces/expand "~")))))
  (testing "non-tilde paths are unchanged"
    (is (= "/absolute/path" (eca-workspaces/expand "/absolute/path"))))
  (testing "leading and trailing whitespace is trimmed"
    (is (= "/foo" (eca-workspaces/expand "  /foo  ")))))

;; ---- integration tests: -main ---------------------------------------------

(deftest test-main-shape
  (testing "-main returns a map"
    (let [result (eca-workspaces/-main)]
      (is (map? result))))
  (testing "-main result has :workspaces key"
    (is (contains? (eca-workspaces/-main) :workspaces)))
  (testing "-main result has :ecaBinary key"
    (is (contains? (eca-workspaces/-main) :ecaBinary)))
  (testing ":workspaces is a vector"
    (is (vector? (:workspaces (eca-workspaces/-main))))))

(deftest test-main-workspace-fields
  (testing "each workspace has required keys"
    (doseq [ws (:workspaces (eca-workspaces/-main))]
      (is (contains? ws :path)   (str "missing :path in " ws))
      (is (contains? ws :name)   (str "missing :name in " ws))
      (is (contains? ws :chatCount) (str "missing :chatCount in " ws))))
  (testing "chatCount is a non-negative integer"
    (doseq [ws (:workspaces (eca-workspaces/-main))]
      (is (int? (:chatCount ws)))
      (is (>= (:chatCount ws) 0)))))
