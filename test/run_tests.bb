#!/usr/bin/env bb
;; Test runner for omarchy-eca.
;;
;; Run from the project root:
;;   bb test/run_tests.bb
;;
;; Or via the bb task:
;;   bb test
(ns run-tests
  (:require [clojure.test :as t]
            [babashka.fs :as fs]))

;; ---- resolve project root --------------------------------------------------
;; *file* is this script's absolute path; its parent is test/, parent of that
;; is the project root.  Exposed as a plain def so integration tests can
;; reference it via (resolve 'run-tests/project-root).
(def project-root
  (str (fs/parent (fs/parent (fs/absolutize *file*)))))

;; ---- load scripts as libraries (main guards prevent execution) -------------
;; load-file uses CWD-relative paths; cd to the project root first so the
;; scripts' own relative references (cache-root, etc.) resolve correctly.
(System/setProperty "user.dir" project-root)

(println "Loading eca_workspaces.bb …")
(binding [*command-line-args* []]
  (load-file (str project-root "/eca_workspaces.bb")))

(println "Loading eca_bridge.bb …")
(binding [*command-line-args* []]
  (load-file (str project-root "/eca_bridge.bb")))

;; ---- load and register test namespaces -------------------------------------
;; Test files reference run-tests/project-root via (resolve ...) for absolute
;; paths to the scripts under test.
(println "Loading tests …")
(load-file (str project-root "/test/eca_workspaces_test.bb"))
(load-file (str project-root "/test/eca_bridge_test.bb"))

;; ---- run -------------------------------------------------------------------
(println "\n========== omarchy-eca test suite ==========\n")

(let [{:keys [fail error]}
      (t/run-tests 'eca-workspaces-test 'eca-bridge-test)]
  (println)
  (if (= 0 fail error)
    (do (println "✓ All tests passed.") (System/exit 0))
    (do (println (str "✗ " (+ fail error) " failure(s)/error(s).")) (System/exit 1))))
