// Jenkins CI pipeline for Attention Copilot: Linux desktop build + Harbor archive.
//
// Trigger:  GitHub push webhook -> boseman nginx relay (/jenkins-hook/) ->
//           generic-webhook-trigger. Webhook-only on purpose: no pollSCM
//           (same lesson as tiktok-helper-ci).
// Build:    main pushes only; other branches and PR events exit as no-ops,
//           because the public GitHub Actions CI already covers them.
// Tooling:  everything runs in the pinned attention-copilot-flutter:3.47.4
//           image (see ci/jenkins/Dockerfile), self-healing via docker build.
//           Containers run as uid 1000 so files written into the workspace
//           stay owned by the agent user and cleanWs() can remove them.
// Archive:  the release bundle is tarballed and pushed to Harbor as an OCI
//           artifact: apps/attention-copilot, tags sha-<7> and latest.
//
// Required Jenkins credentials:
//   - attention-copilot-harbor : Harbor robot$apps+ci secret (secret text)
//
// The generic-webhook-trigger itself is configured on the job (not here),
// matching the tiktok-helper-ci house style.

def isCiRun() {
  // Push events carry refs/heads/main; manual builds have no BRANCH and
  // always target the job's configured branch (main).
  return (env.BRANCH ?: 'refs/heads/main') == 'refs/heads/main'
}

pipeline {
  agent { label 'build' }

  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
  }

  environment {
    CI = 'true'
    FLUTTER_IMAGE = 'attention-copilot-flutter:3.47.4'
    HARBOR_REGISTRY = 'harbor.webmasters.co.at'
    HARBOR_ARTIFACT = 'apps/attention-copilot'
    HARBOR_USER = 'robot$apps+ci'
  }

  stages {
    stage('triage') {
      steps {
        echo "no-op: BRANCH='${env.BRANCH ?: '-'}' AFTER='${env.AFTER ?: '-'}'"
      }
    }

    stage('checkout') {
      when { expression { isCiRun() } }
      steps {
        checkout([
          $class: 'GitSCM',
          branches: [[name: env.AFTER ?: '*/main']],
          userRemoteConfigs: [[
            url: 'https://github.com/hrohrweck/attention-copilot.git'
          ]],
          extensions: [[$class: 'CloneOption', depth: 1, noTags: true, shallow: true]]
        ])
        script {
          env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
        }
      }
    }

    stage('toolchain') {
      when { expression { isCiRun() } }
      steps {
        sh 'docker image inspect ${FLUTTER_IMAGE} >/dev/null 2>&1 || docker build -q -f ci/jenkins/Dockerfile -t ${FLUTTER_IMAGE} .'
      }
    }

    stage('analyze') {
      when { expression { isCiRun() } }
      steps {
        sh '''docker run --rm -u 1000:1000 \
              -v "$PWD":/workspace -w /workspace \
              -v attention-copilot-pub-cache:/home/ubuntu \
              -e CI=true \
              attention-copilot-flutter:3.47.4 \
              flutter analyze'''
      }
    }

    stage('test') {
      when { expression { isCiRun() } }
      steps {
        sh '''docker run --rm -u 1000:1000 \
              -v "$PWD":/workspace -w /workspace \
              -v attention-copilot-pub-cache:/home/ubuntu \
              -e CI=true \
              attention-copilot-flutter:3.47.4 \
              flutter test'''
      }
    }

    stage('build linux') {
      when { expression { isCiRun() } }
      steps {
        sh '''docker run --rm -u 1000:1000 \
              -v "$PWD":/workspace -w /workspace \
              -v attention-copilot-pub-cache:/home/ubuntu \
              -e CI=true \
              attention-copilot-flutter:3.47.4 \
              flutter build linux --release'''
        script {
          env.APP_VERSION = sh(
            returnStdout: true,
            script: "grep -E '^version:' pubspec.yaml | sed -E 's/version: *([0-9]+\\.[0-9]+\\.[0-9]+).*/\\1/'"
          ).trim()
        }
        sh 'mkdir -p dist && tar -czf "dist/attention-copilot-${APP_VERSION}+${BUILD_NUMBER}-linux-x64.tar.gz" -C build/linux/x64/release bundle'
      }
    }

    stage('archive to harbor') {
      when { expression { isCiRun() } }
      steps {
        script {
          env.ARTIFACT_FILE = "attention-copilot-${env.APP_VERSION}+${env.BUILD_NUMBER}-linux-x64.tar.gz"
          env.ORAS_REF = "${env.HARBOR_REGISTRY}/${env.HARBOR_ARTIFACT}:sha-${env.SHORT_SHA},latest"
        }
        withCredentials([string(credentialsId: 'attention-copilot-harbor', variable: 'HARBOR_SECRET')]) {
          sh '''printf '%s' "$HARBOR_SECRET" | docker run -i --rm -u 1000:1000 \
                -v "$PWD/dist":/artifacts -w /artifacts \
                ghcr.io/oras-project/oras:v1.4.0 \
                push --username "$HARBOR_USER" --password-stdin \
                --artifact-type application/vnd.attention-copilot+bundle \
                "$ORAS_REF" "$ARTIFACT_FILE"'''
        }
      }
    }
  }

  post {
    success {
      echo "Archived ${env.HARBOR_REGISTRY}/${env.HARBOR_ARTIFACT}:sha-${env.SHORT_SHA} (${env.APP_VERSION}+${env.BUILD_NUMBER})"
    }
    failure {
      echo 'Pipeline failed - no artifact was pushed to Harbor.'
    }
    always {
      cleanWs()
    }
  }
}
