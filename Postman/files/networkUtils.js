/**
 * Adaptive authentication script library used by the E2E suite.
 *
 * Replaces a postman-cloud:/// upload that only resolved inside the Postman
 * app, which made every script-library test fail under newman.
 */

function getIpAddress(context) {
    return context.request.ip;
}

function getUserAgent(context) {
    return context.request.headers["user-agent"];
}

function isPrivateNetwork(ip) {
    if (!ip) {
        return false;
    }
    return ip.indexOf("10.") === 0
        || ip.indexOf("192.168.") === 0
        || ip.indexOf("172.") === 0;
}
