# Device image for a UML device: kathara/base plus the ssh client that
# /kathara-uml/ushell uses to reach the UML (kathara/base has sshd but no
# client). Host keys for the sshd that runs inside the UML.
FROM kathara/base
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client && \
	rm -rf /var/lib/apt/lists/* && ssh-keygen -A
