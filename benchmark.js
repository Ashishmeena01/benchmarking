import http from "k6/http";
import { check } from "k6";


export const options = {
    vus: Number(__ENV.VUS || 50),
    duration: __ENV.DURATION || "15s",
    noConnectionReuse: true,
    summaryTrendStats: [
        "avg",
        "min",
        "med",
        "max",
        "p(90)",
        "p(95)",
        "p(99)"
    ]
};

export default function () {
    const response = http.get("http://127.0.0.1:8080/");

    check(response, {
        "status is 200": (r) => r.status === 200,
        "correct body": (r) => r.body === "Hello World\n"
    });
}