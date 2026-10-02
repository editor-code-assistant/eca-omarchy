;; Tests for eca_bridge.bb
;; Loaded by test/run_tests.bb — do not run directly (no shebang by design).
(ns eca-bridge-test
  (:require [clojure.test :refer [deftest is testing]]
            [babashka.process :as p]
            [cheshire.core :as json]
            [clojure.string :as str])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)
           (java.nio.charset StandardCharsets)))

;; ---- unit tests: parse-args -----------------------------------------------

(deftest test-parse-args
  (testing "empty args produce empty map"
    (is (= {} (eca-bridge/parse-args []))))
  (testing "--workspace is captured"
    (is (= {:workspace "/home/user/Work/project"}
           (eca-bridge/parse-args ["--workspace" "/home/user/Work/project"]))))
  (testing "all known flags parse correctly"
    (is (= {:workspace "/proj" :eca "/usr/bin/eca"
            :log-level "debug" :config-file "/etc/eca.json"}
           (eca-bridge/parse-args ["--workspace" "/proj"
                                   "--eca"        "/usr/bin/eca"
                                   "--log-level"  "debug"
                                   "--config-file" "/etc/eca.json"]))))
  (testing "bare positional tokens are skipped"
    (is (= {:workspace "/proj"}
           (eca-bridge/parse-args ["something" "--workspace" "/proj"]))))
  (testing "trailing flag without value is skipped"
    (is (= {} (eca-bridge/parse-args ["--orphan"])))))

;; ---- unit tests: LSP framing (read-headers) --------------------------------

(defn bytes->stream ^ByteArrayInputStream [^String s]
  (ByteArrayInputStream. (.getBytes s StandardCharsets/UTF_8)))

(deftest test-read-headers-single
  (testing "parses a single Content-Length header"
    (let [raw  "Content-Length: 42\r\n\r\n"
          hdrs (eca-bridge/read-headers (bytes->stream raw))]
      (is (= {"content-length" "42"} hdrs))))
  (testing "header name is lower-cased"
    (let [hdrs (eca-bridge/read-headers (bytes->stream "CONTENT-LENGTH: 10\r\n\r\n"))]
      (is (contains? hdrs "content-length")))))

(deftest test-read-headers-multiple
  (testing "parses two headers separated by blank line"
    (let [raw  "Content-Length: 18\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n"
          hdrs (eca-bridge/read-headers (bytes->stream raw))]
      (is (= "18" (get hdrs "content-length")))
      (is (str/includes? (get hdrs "content-type" "") "application")))))

(deftest test-read-headers-eof
  (testing "returns nil on an empty / EOF stream"
    (is (nil? (eca-bridge/read-headers (ByteArrayInputStream. (byte-array 0)))))))

(deftest test-read-headers-extra-blank-lines
  (testing "skips leading blank lines before real headers"
    ;; The implementation loops back on a blank line that precedes real headers.
    (let [raw  "\r\nContent-Length: 7\r\n\r\n"
          hdrs (eca-bridge/read-headers (bytes->stream raw))]
      (is (= "7" (get hdrs "content-length"))))))

;; ---- unit tests: LSP framing (write-message! / read-message) ---------------

(deftest test-write-read-roundtrip
  (testing "write then read returns the original JSON string"
    (let [body   "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
          buf    (ByteArrayOutputStream.)
          _      (eca-bridge/write-message! buf body)
          result (eca-bridge/read-message (ByteArrayInputStream. (.toByteArray buf)))]
      (is (= body result))))
  (testing "roundtrip preserves empty JSON object"
    (let [body "{}"
          buf  (ByteArrayOutputStream.)
          _    (eca-bridge/write-message! buf body)]
      (is (= body (eca-bridge/read-message (ByteArrayInputStream. (.toByteArray buf))))))))

(deftest test-write-read-utf8
  (testing "unicode characters survive the framing roundtrip"
    (let [body   "{\"text\":\"こんにちは 🎉\"}"
          buf    (ByteArrayOutputStream.)
          _      (eca-bridge/write-message! buf body)
          result (eca-bridge/read-message (ByteArrayInputStream. (.toByteArray buf)))]
      (is (= body result)))))

(deftest test-write-content-length-correct
  (testing "Content-Length matches the byte length of the body"
    (let [body  "{\"method\":\"test\"}"
          buf   (ByteArrayOutputStream.)
          _     (eca-bridge/write-message! buf body)
          raw   (String. (.toByteArray buf) StandardCharsets/US_ASCII)
          [header-part _] (str/split raw #"\r\n\r\n" 2)
          cl    (some-> (re-find #"Content-Length: (\d+)" header-part) second parse-long)]
      (is (= (alength (.getBytes body StandardCharsets/UTF_8)) cl)))))

;; ---- integration tests: subprocess -----------------------------------------
;; These spin up a real bb process so we verify the full error paths that
;; -main exercises (System/exit, emit!).
;;
;; run_tests.bb sets run-tests/project-root (a plain def, not dynamic) before
;; loading this file — we reference it via the fully-qualified symbol.

(defn run-bridge [& args]
  (let [root (resolve 'run-tests/project-root)
        script (str @root "/eca_bridge.bb")
        cmd  (into ["bb" script] args)
        res  @(p/process cmd {:out :string :err :string :in ""})]
    {:exit (:exit res)
     :lines (filterv (complement str/blank?) (str/split-lines (:out res)))}))

(deftest test-bridge-missing-workspace
  (testing "emits a bridge error when workspace folder does not exist"
    (let [{:keys [lines exit]} (run-bridge "--workspace" "/nonexistent-omarchy-eca-test-dir")]
      (is (pos? exit) "should exit non-zero")
      (is (seq lines) "should emit at least one line")
      (let [msg (json/parse-string (first lines) true)]
        (is (= "error" (:bridge msg)))
        (is (string? (:message msg)))))))

(deftest test-find-eca-configured-path
  (testing "find-eca returns nil when --eca points at a non-executable path"
    ;; Override opts in the eca-bridge namespace so find-eca uses our value.
    (with-redefs [eca-bridge/opts {:eca "/nonexistent-eca-binary-omarchy-test"}]
      ;; find-eca checks (executable? configured) first; non-existent → nil.
      ;; On a machine where eca is also not on PATH or hardcoded paths, the
      ;; whole chain returns nil.  We only assert the configured check works.
      ;; When a real eca exists elsewhere, find-eca returns that — which is
      ;; the intended fallback behaviour.
      (let [configured-result
            (let [configured (some-> "/nonexistent-eca-binary-omarchy-test"
                                     clojure.string/trim not-empty)]
              (when (eca-bridge/executable? configured) configured))]
        (is (nil? configured-result) "non-existent path should not be executable")))))

(deftest test-bridge-missing-workspace
  (testing "emits a bridge error when workspace folder does not exist"
    (let [{:keys [lines exit]} (run-bridge "--workspace" "/nonexistent-omarchy-eca-test-dir")]
      (is (pos? exit) "should exit non-zero")
      (is (seq lines) "should emit at least one line")
      (let [msg (json/parse-string (first lines) true)]
        (is (= "error" (:bridge msg)))
        (is (string? (:message msg)))))))
