# Custom Spark image: Stackable 3.5.8 runtime + this project's job JAR.
# Built by Tekton (maven package, then buildah) into ImageStream spark-churn-java.
FROM quay.io/stackable/sdp/spark-k8s:3.5.8-stackable26.7.0

USER root
RUN mkdir -p /stackable/spark/jobs && chown -R stackable:stackable /stackable/spark/jobs
COPY --chown=stackable:stackable target/churn-score-job-1.0.0.jar /stackable/spark/jobs/churn-score.jar
USER stackable
