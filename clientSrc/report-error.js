(function () {
    // dec2hex :: Integer -> String
    // i.e. 0-255 -> '00'-'ff'
    function dec2hex (dec) {
        return ('0' + dec.toString(16)).substr(-2);
    }

    // generateId :: Integer -> String
    function generateId (len) {
        var arr = new Uint8Array((len || 40) / 2);
        window.crypto.getRandomValues(arr);
        return Array.from(arr, dec2hex).join('');
    }

    var session = generateId(20);

    function reportSomething(type, obj) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', "@reportingUrl@", true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.send(JSON.stringify({
            session: session,
            app: "@appName@",
            type: type,
            data: obj,
        }));
    }

    window.onerror = function (msg, url, line, column, error) {
        reportSomething("jsError", {msg: msg, url: url, line: line, column: column, error: error});

        return false;
    };

    window.kwiius_reportError = reportSomething;
})();
