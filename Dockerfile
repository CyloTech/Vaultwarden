FROM vaultwarden/server:1.37.1

RUN apt-get update && \
    apt-get install -y --no-install-recommends gosu jq python3 && \
    rm -rf /var/lib/apt/lists/*

ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
ADD register_user.py /register_user.py
ADD appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod +x /entrypoint.sh /moduser.sh /register_user.py && chmod 755 /usr/local/bin/appbox-installed-callback

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/vaultwarden"]

EXPOSE 80
