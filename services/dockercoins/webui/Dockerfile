FROM node:18-slim

WORKDIR /usr/app

RUN apt-get update && apt-get install -y python3 make g++ && rm -rf /var/lib/apt/lists/*

COPY package.json .
RUN npm install

COPY files/ ./files/
COPY webui.js .

RUN mkdir -p exports

CMD ["node", "webui.js"]
EXPOSE 80
