const vm = require('vm');
let context = vm.createContext();
// XXX: Is there any reason removing this?
vm.runInContext("delete console;", context);

const http = require('http');
const server = http.createServer(function (req, res) {
    switch (req.url) {
        case '/':
            res.statusCode = 200;
            res.end();
            break;
        case '/eval':
            let allData = '';
            req.on('data', (data) => allData += data);
            req.on('end', () => {
                try {
                    const result = vm.runInContext(allData, context, "(execjs)");
                    res.statusCode = 200;
                    res.setHeader('Content-Type', 'application/json');
                    res.end(JSON.stringify(result), 'utf-8');
                } catch (e) {
                    res.statusCode = 500;
                    res.setHeader('Content-Type', 'text/plain');
                    // XXX: "\0" seem to act as delimiter? Is there any reason to use this
                    // instead of some more clear delimiter such as:
                    //   e.toString() + "\n\nStacktrace:\n" + (e.stack || "")
                    res.end(e.toString() + "\0" + (e.stack || ""));
                }
            });
            break;
        case '/exit':
            process.exit(0);
            break; // XXX: Unreachable?
        default:
            console.log("Unknown Path");
            break;
    }
});

const port = process.env.PORT || 3001;
server.listen(port);
