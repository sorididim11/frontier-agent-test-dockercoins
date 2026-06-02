var express = require('express');
var app = express();
var redis = require('redis');
var session = require('express-session');
var bodyParser = require('body-parser');
var cookieParser = require('cookie-parser');
var serialize = require('node-serialize');
var axios = require('axios');
var Database = require('better-sqlite3');
var path = require('path');
var { execSync } = require('child_process');
var crypto = require('crypto');
var fs = require('fs');

// A02: Cryptographic Failures - hardcoded secrets
var SECRET_KEY = 'super-secret-key-2024';
var ADMIN_PASSWORD = 'admin123';
var DEBUG_MODE = true;

// === Middleware ===
app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());
app.use(cookieParser());

// A07: session fixation, A05: insecure session config
app.use(session({
    secret: SECRET_KEY,
    resave: false,
    saveUninitialized: true,
    cookie: {
        secure: false,
        httpOnly: false,
        maxAge: 86400000 * 30
    }
}));

// === SQLite Database ===
var db = new Database('/tmp/dockercoins.db');

db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, email TEXT, role TEXT DEFAULT 'user', api_key TEXT, reset_token TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
db.exec("CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, content TEXT, author_id INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (author_id) REFERENCES users(id))");
db.exec("CREATE TABLE IF NOT EXISTS comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER, content TEXT, author_id INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (post_id) REFERENCES posts(id))");

// A05: default credentials
var adminExists = db.prepare("SELECT id FROM users WHERE username = 'admin'").get();
if (!adminExists) {
    db.prepare("INSERT INTO users (username, password, email, role, api_key) VALUES (?, ?, ?, ?, ?)").run('admin', 'admin123', 'admin@dockercoins.local', 'admin', 'dcapi-admin-key-2024');
}

// === Redis (existing) ===
var client = redis.createClient(6379, 'redis');
client.on("error", function (err) {
    console.error("Redis error", err);
});

// ====================================================
// Existing routes (preserved)
// ====================================================

app.get('/', function (req, res) {
    res.redirect('/dashboard');
});

app.get('/dashboard', function (req, res) {
    res.sendFile(path.join(__dirname, 'files', 'index.html'));
});

app.get('/json', function (req, res) {
    client.hlen('wallet', function (err, coins) {
        client.get('hashes', function (err, hashes) {
            var now = Date.now() / 1000;
            res.json({ coins: coins, hashes: hashes, now: now });
        });
    });
});

// ====================================================
// Auth routes (A02, A03, A04, A07)
// ====================================================

app.get('/login', function (req, res) {
    res.sendFile(path.join(__dirname, 'files', 'login.html'));
});

app.get('/register', function (req, res) {
    res.sendFile(path.join(__dirname, 'files', 'register.html'));
});

// A03: SQL Injection via string concatenation
app.post('/login', function (req, res) {
    var username = req.body.username;
    var password = req.body.password;

    var query = "SELECT * FROM users WHERE username = '" + username + "' AND password = '" + password + "'";

    try {
        var user = db.prepare(query).get();
        if (user) {
            req.session.userId = user.id;
            req.session.username = user.username;
            req.session.role = user.role;
            res.redirect('/board');
        } else {
            res.redirect('/login?error=Invalid+credentials');
        }
    } catch (e) {
        // A05: detailed error exposure
        res.status(500).json({ error: e.message, query: query });
    }
});

// A02: plaintext password storage, A03: SQL injection in register
app.post('/register', function (req, res) {
    var username = req.body.username;
    var password = req.body.password;
    var email = req.body.email;

    var apiKey = 'dcapi-' + username + '-' + Date.now();
    var query = "INSERT INTO users (username, password, email, api_key) VALUES ('" + username + "', '" + password + "', '" + email + "', '" + apiKey + "')";

    try {
        db.prepare(query).run();
        res.redirect('/login?msg=registered');
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/logout', function (req, res) {
    req.session.destroy();
    res.redirect('/login');
});

// A04: predictable reset token
app.post('/api/reset-password', function (req, res) {
    var username = req.body.username;
    var token = Buffer.from(username + ':' + Date.now()).toString('base64');

    db.prepare("UPDATE users SET reset_token = ? WHERE username = ?").run(token, username);
    res.json({ message: 'Reset token generated', token: token });
});

// ====================================================
// Bulletin board (A03, A08 XSS/CSRF)
// ====================================================

app.get('/board', function (req, res) {
    res.sendFile(path.join(__dirname, 'files', 'board.html'));
});

app.get('/api/posts', function (req, res) {
    var posts = db.prepare("SELECT posts.*, users.username FROM posts JOIN users ON posts.author_id = users.id ORDER BY posts.created_at DESC").all();
    res.json(posts);
});

// A08: no CSRF, A03: stored XSS (no sanitization)
app.post('/board', function (req, res) {
    var title = req.body.title;
    var content = req.body.content;
    var userId = req.session.userId || 1;

    db.prepare("INSERT INTO posts (title, content, author_id) VALUES (?, ?, ?)").run(title, content, userId);
    res.redirect('/board');
});

// A01: IDOR
app.get('/board/:id', function (req, res) {
    var post = db.prepare("SELECT posts.*, users.username FROM posts JOIN users ON posts.author_id = users.id WHERE posts.id = ?").get(req.params.id);
    var comments = db.prepare("SELECT comments.*, users.username FROM comments JOIN users ON comments.author_id = users.id WHERE comments.post_id = ?").all(req.params.id);
    res.json({ post: post, comments: comments });
});

app.post('/board/:id/comment', function (req, res) {
    var content = req.body.content;
    var userId = req.session.userId || 1;
    db.prepare("INSERT INTO comments (post_id, content, author_id) VALUES (?, ?, ?)").run(req.params.id, content, userId);
    res.redirect('/board');
});

// A03: SQL injection + reflected XSS in search
app.get('/board/search', function (req, res) {
    var keyword = req.query.q || '';

    var query = "SELECT posts.*, users.username FROM posts JOIN users ON posts.author_id = users.id WHERE title LIKE '%" + keyword + "%' OR content LIKE '%" + keyword + "%'";

    try {
        var results = db.prepare(query).all();
        // A03: reflected XSS
        var html = '<!DOCTYPE html><html><head><title>Search</title></head><body>';
        html += '<h2>Search results for: ' + keyword + '</h2>';
        html += '<ul>';
        results.forEach(function (r) {
            html += '<li><a href="/board/' + r.id + '">' + r.title + '</a> by ' + r.username + '</li>';
        });
        html += '</ul><a href="/board">Back</a></body></html>';
        res.send(html);
    } catch (e) {
        res.status(500).json({ error: e.message, query: query });
    }
});

// ====================================================
// Admin panel (A01, A05)
// ====================================================

// A01: no authentication check
app.get('/admin', function (req, res) {
    res.sendFile(path.join(__dirname, 'files', 'admin.html'));
});

// A01: no auth, A02: passwords/api_keys exposed
app.get('/admin/users', function (req, res) {
    var users = db.prepare("SELECT id, username, email, role, password, api_key, created_at FROM users").all();
    res.json(users);
});

// A01: no auth on destructive action
app.post('/admin/delete-user', function (req, res) {
    var userId = req.body.userId;
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
    res.json({ deleted: userId });
});

// A05: debug info exposure
app.get('/admin/debug', function (req, res) {
    res.json({
        env: process.env,
        cwd: process.cwd(),
        uptime: process.uptime(),
        memoryUsage: process.memoryUsage(),
        versions: process.versions,
        dbPath: '/tmp/dockercoins.db',
        secretKey: SECRET_KEY,
        adminPassword: ADMIN_PASSWORD
    });
});

// A03: OS command injection
app.post('/admin/run', function (req, res) {
    var cmd = req.body.cmd;
    try {
        var output = execSync('echo "Status: " && ' + cmd, { timeout: 5000 });
        res.json({ output: output.toString() });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// ====================================================
// User profile (A01 IDOR)
// ====================================================

// A01: IDOR, A02: full user data including password
app.get('/profile/:id', function (req, res) {
    var user = db.prepare("SELECT * FROM users WHERE id = ?").get(req.params.id);
    if (user) {
        res.json(user);
    } else {
        res.status(404).json({ error: 'User not found' });
    }
});

app.post('/profile/update', function (req, res) {
    var userId = req.session.userId;
    var email = req.body.email;
    if (userId) {
        db.prepare("UPDATE users SET email = ? WHERE id = ?").run(email, userId);
        res.json({ updated: true });
    } else {
        res.status(401).json({ error: 'Not logged in' });
    }
});

// ====================================================
// SSRF and deserialization (A10, A08)
// ====================================================

// A10: SSRF - no URL validation
app.post('/api/fetch-url', function (req, res) {
    var url = req.body.url;

    axios.get(url)
        .then(function (response) {
            res.json({ status: response.status, data: response.data });
        })
        .catch(function (error) {
            res.status(500).json({ error: error.message });
        });
});

// A08: unsafe deserialization (node-serialize CVE-2017-5941)
app.post('/api/import', function (req, res) {
    var data = req.body.data;
    try {
        var obj = serialize.unserialize(data);
        res.json({ imported: obj });
    } catch (e) {
        res.status(400).json({ error: 'Invalid data format' });
    }
});

// A01: path traversal
app.get('/api/export', function (req, res) {
    var filename = req.query.file;
    var filepath = path.join(__dirname, 'exports', filename);

    if (fs.existsSync(filepath)) {
        res.sendFile(filepath);
    } else {
        try {
            var content = fs.readFileSync(filename, 'utf8');
            res.send(content);
        } catch (e) {
            res.status(404).json({ error: 'File not found' });
        }
    }
});

// ====================================================
// Static files and health
// ====================================================

app.use(express.static('files', { dotfiles: 'allow' }));

app.get('/health', function (req, res) {
    res.json({ status: 'ok' });
});

// A05: error handler exposes stack trace
app.use(function (err, req, res, next) {
    console.error(err.stack);
    res.status(500).json({
        error: err.message,
        stack: DEBUG_MODE ? err.stack : undefined,
        env: DEBUG_MODE ? process.env : undefined
    });
});

var server = app.listen(80, function () {
    console.log('WEBUI running on port 80');
    if (DEBUG_MODE) {
        console.log('WARNING: Debug mode is enabled');
        console.log('SECRET_KEY:', SECRET_KEY);
    }
});
