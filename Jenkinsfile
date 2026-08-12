pipeline {
    agent any

    triggers {

    }
    environment {
        IMAGE_NAME = 'notes-app'
        REGISTRY = 'docker.io/yourorg'
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        HELM_RELEASE = 'notes'
        NAMESPACE = 'default'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build image') {
            steps {
                sh 'docker build -t $REGISTRY/$IMAGE_NAME:$IMAGE_TAG -t $REGISTRY/$IMAGE_NAME:latest .'
            }
        }

        stage('Lint chart') {
            steps {
                sh 'helm lint helm/notes-app'
            }
        }

        stage('Push image') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                        usernameVariable: 'DOCKER_USER',
                        passwordVariable: 'DOCKER_PASS')]) {
                    sh '''
            echo "$DOCKER_PASS" | docker login docker.io -u "$DOCKER_USER" --password-stdin
            docker push $REGISTRY/$IMAGE_NAME:$IMAGE_TAG
            docker push $REGISTRY/$IMAGE_NAME:latest
          '''
                }
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
            helm upgrade --install $HELM_RELEASE helm/notes-app \
              --namespace $NAMESPACE --create-namespace \
              --set image.repository=$REGISTRY/$IMAGE_NAME \
              --set image.tag=$IMAGE_TAG \
              --wait
          '''
                }
            }
        }
    }

    post {
        always {
            sh 'docker logout docker.io || true'
        }
    }
}
