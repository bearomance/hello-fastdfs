# 使用超小的Linux镜像alpine
FROM alpine:3.12

ENV HOME /root

# 安装准备
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk update \
    && apk add --no-cache --virtual .build-deps bash gcc libc-dev make openssl-dev pcre-dev zlib-dev linux-headers curl gnupg libxslt-dev gd-dev geoip-dev git wget

# 复制工具
ADD soft ${HOME}

RUN cd ${HOME} \
    && tar xvf libfastcommon-master.tar.gz \
    && tar xvf fastdfs-master.tar.gz \
    && tar xvf fastdfs-nginx-module-master.tar.gz \
    && tar xvf nginx-1.19.1.tar.gz

# 安装libfastcommon
RUN     cd ${HOME}/libfastcommon-master/ \
        && ./make.sh \
        && ./make.sh install

# 安装fastdfs
RUN     cd ${HOME}/fastdfs-master/ \
        && ./make.sh \
        && ./make.sh install

# 配置fastdfs: base_dir
RUN     cd /etc/fdfs/ \
        && cp storage.conf.sample storage.conf \
        && cp tracker.conf.sample tracker.conf \
        && cp client.conf.sample client.conf \
        && sed -i "s|/home/yuqing/fastdfs|/var/local/fdfs/tracker|g" /etc/fdfs/tracker.conf \
        && sed -i "s|/home/yuqing/fastdfs|/var/local/fdfs/storage|g" /etc/fdfs/storage.conf \
        && sed -i "s|/home/yuqing/fastdfs|/var/local/fdfs/storage|g" /etc/fdfs/client.conf

# 获取nginx源码，与fastdfs插件一起编译
RUN     cd ${HOME} \
        && chmod u+x ${HOME}/fastdfs-nginx-module-master/src/config \
        && cd nginx-1.19.1 \
        && ./configure --add-module=${HOME}/fastdfs-nginx-module-master/src \
        && make && make install

# 设置nginx和fastdfs联合环境，并配置nginx
RUN     cp ${HOME}/fastdfs-nginx-module-master/src/mod_fastdfs.conf /etc/fdfs/ \
        && sed -i "s|^store_path0.*$|store_path0=/var/local/fdfs/storage|g" /etc/fdfs/mod_fastdfs.conf \
        && sed -i "s|^url_have_group_name =.*$|url_have_group_name = true|g" /etc/fdfs/mod_fastdfs.conf \
        && cd ${HOME}/fastdfs-master/conf/ \
        && cp http.conf mime.types anti-steal.jpg /etc/fdfs/ \
        && echo -e "\
           events {\n\
           worker_connections  1024;\n\
           }\n\
           http {\n\
           include       mime.types;\n\
           default_type  application/octet-stream;\n\
           server {\n\
               listen 80;\n\
               server_name localhost;\n\
               add_header Content-Disposition 'attachment;filename=\$arg_attname';\n\
               location ~ /group[0-9]/M00 {\n\
                 ngx_fastdfs_module;\n\
               }\n\
             }\n\
            }" >/usr/local/nginx/conf/nginx.conf
# 清理文件
RUN rm -rf ${HOME}/*
RUN apk del .build-deps gcc libc-dev make openssl-dev linux-headers curl gnupg libxslt-dev gd-dev geoip-dev
RUN apk add bash pcre-dev zlib-dev

# 设置时区
ENV TZ Asia/Shanghai
RUN apk add -U tzdata
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 配置启动脚本，在启动时中根据环境变量替换nginx端口、fastdfs端口
# 默认nginx端口
ENV NGINX_PORT 8888
# 默认track_server端口
ENV TRACKER_PORT 22122
# 默认storage_server端口
ENV STORAGE_PORT 23000

# 创建启动脚本
RUN echo -e "\
mkdir -p /var/local/fdfs/storage/data /var/local/fdfs/tracker; \n\
sed -i \"s/listen\ .*$/listen\ \$NGINX_PORT;/g\" /usr/local/nginx/conf/nginx.conf; \n\
sed -i \"s/http.server_port=.*$/http.server_port=\$NGINX_PORT/g\" /etc/fdfs/storage.conf; \n\
if [ \"\$IP\" = \"\" ]; then \n\
    IP=\`ifconfig eth0 | grep inet | awk '{print \$2}'| awk -F: '{print \$2}'\`; \n\
fi \n\
IP=(\${IP//,/ }); \n\
sed -i \"s/^tracker_server=.*$/tracker_server=\${IP[0]}:\$TRACKER_PORT/g\" /etc/fdfs/client.conf; \n\
sed -i \"s/^tracker_server=.*$/tracker_server=\${IP[0]}:\$TRACKER_PORT/g\" /etc/fdfs/storage.conf; \n\
sed -i \"s/^tracker_server=.*$/tracker_server=\${IP[0]}:\$TRACKER_PORT/g\" /etc/fdfs/mod_fastdfs.conf; \n\
for ((i=1; i<\${#IP[*]}; i++)) \n\
  do \n\
    sed -i \"/tracker_server=\${IP[i-1]}:\$TRACKER_PORT/atracker_server=\${IP[i]}:\$TRACKER_PORT\" /etc/fdfs/client.conf; \n\
    sed -i \"/tracker_server=\${IP[i-1]}:\$TRACKER_PORT/atracker_server=\${IP[i]}:\$TRACKER_PORT\" /etc/fdfs/storage.conf; \n\
    sed -i \"/tracker_server=\${IP[i-1]}:\$TRACKER_PORT/atracker_server=\${IP[i]}:\$TRACKER_PORT\" /etc/fdfs/mod_fastdfs.conf; \n\
  done \n\
sed -i \"s/^port=.*$/port=\$TRACKER_PORT/\" /etc/fdfs/tracker.conf; \n\
sed -i \"s/^port=.*$/port=\$STORAGE_PORT/g\" /etc/fdfs/storage.conf; \n\
sed -i \"s/^storage_server_port=.*$/storage_server_port=\$STORAGE_PORT/g\" /etc/fdfs/mod_fastdfs.conf; \n\
sed -i \"s/^keep_alive=.*$/keep_alive=1/g\" /etc/fdfs/storage.conf; \n\
/etc/init.d/fdfs_trackerd start; \n\
/etc/init.d/fdfs_storaged start; \n\
/usr/local/nginx/sbin/nginx; \n\
tail -f /usr/local/nginx/logs/access.log \
">/start.sh \
&& chmod u+x /start.sh
ENTRYPOINT ["/bin/bash","/start.sh"]
