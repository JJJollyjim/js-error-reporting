#![feature(proc_macro_hygiene, decl_macro, never_type)]
#![warn(clippy::all)]

#[macro_use]
extern crate rocket;
use backoff::{ExponentialBackoff, Operation};
use chrono::Utc;
use rocket::{
    http::{hyper::header, Status},
    request::{FromRequest, Outcome, Request},
    response::Response,
    State,
};
use rocket_contrib::json::Json;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::{sync::mpsc, thread};
use tracing::*;

#[derive(Deserialize, Debug)]
struct Config {
    #[serde(with = "serde_with::rust::display_fromstr")]
    loki_push_url: reqwest::Url,
    loki_job_name: String,

    #[serde(default = "Vec::new")]
    classify_critical: Vec<String>,
    #[serde(default = "Vec::new")]
    classify_error: Vec<String>,
    #[serde(default = "Vec::new")]
    classify_warning: Vec<String>,
    #[serde(default = "Vec::new")]
    classify_info: Vec<String>,
    #[serde(default = "Vec::new")]
    classify_debug: Vec<String>,
    #[serde(default = "Vec::new")]
    classify_trace: Vec<String>,
}

fn classify(conf: &Config, typ: &str) -> &'static str {
    if conf.classify_critical.iter().any(|x| x == typ) {
        "critical"
    } else if conf.classify_error.iter().any(|x| x == typ) {
        "error"
    } else if conf.classify_warning.iter().any(|x| x == typ) {
        "warning"
    } else if conf.classify_info.iter().any(|x| x == typ) {
        "info"
    } else if conf.classify_debug.iter().any(|x| x == typ) {
        "debug"
    } else if conf.classify_trace.iter().any(|x| x == typ) {
        "trace"
    } else {
        warn!(typ, "unclassified type");
        "unknown"
    }
}

#[derive(Deserialize, Debug)]
struct Report {
    session: String,
    app: String,
    #[serde(rename = "type")]
    typ: String,
    data: Box<RawValue>,
}

#[derive(Serialize, Debug)]
struct LokiReq {
    streams: [LokiStream; 1],
}

#[derive(Serialize, Debug)]
struct LokiLabels {
    job: String,
    session: String,
    app: String,
    #[serde(rename = "type")]
    typ: String,
    ua: String,
    loglevel: &'static str,
    // TODO IP? Origin?
}

#[derive(Serialize, Debug)]
struct LokiStream {
    stream: LokiLabels,
    values: [(String, String); 1],
}

fn send_thread(rx: mpsc::Receiver<LokiReq>) {
    let thread_span = info_span!("sender");
    let _enter = thread_span.enter();

    let client = reqwest::blocking::Client::new();
    let mut backoff = ExponentialBackoff::default();
    for item in rx.iter() {
        let item_span = info_span!("send_one");
        let _enter2 = item_span.enter();
        let mut exec = || {
            let attempt_span = info_span!("attempt_send");
            let _enter3 = attempt_span.enter();
            let result = client
                .post("http://localhost:3100/loki/api/v1/push")
                .json(&item)
                .send();
            match result {
                Ok(res) if res.status().is_success() => Ok(res),
                Ok(res)
                    if res.status().is_client_error()
                        && res.status() != reqwest::StatusCode::TOO_MANY_REQUESTS =>
                {
                    res.error_for_status().map_err(backoff::Error::Permanent)
                }
                Ok(res) => res.error_for_status().map_err(backoff::Error::Transient),
                Err(e) => Err(backoff::Error::Transient(e)),
            }
        };

        let res = exec.retry_notify(
            &mut backoff,
            |err, time| (warn!(error = ?err, duration = ?time, "retrying due to transient error")),
        );
        match res {
            Ok(_) => info!("sent successfully"),
            Err(err) => error!(error=?err, "giving up due to error"),
        };
    }
}

struct UserAgent<'a>(&'a str);
impl<'a, 'r> FromRequest<'a, 'r> for UserAgent<'a> {
    type Error = !;

    fn from_request(request: &'a Request<'r>) -> Outcome<Self, Self::Error> {
        match request.headers().get_one("user-agent") {
            Some(user_agent) => Outcome::Success(UserAgent(user_agent)),
            None => Outcome::Forward(()),
        }
    }
}

#[options("/log")]
fn log_opts<'r>() -> Response<'r> {
    Response::build()
        .status(Status::Ok)
        .header(header::AccessControlAllowOrigin::Any)
        .raw_header("Access-Control-Allow-Headers", "Content-Type")
        .finalize()
}

#[post("/log", format = "json", data = "<data>")]
fn log<'r>(
    data: Json<Report>,
    ua: UserAgent,
    tx: State<mpsc::SyncSender<LokiReq>>,
    conf: State<Config>,
) -> Response<'r> {
    let data = data.into_inner();
    let req = LokiReq {
        streams: [LokiStream {
            stream: LokiLabels {
                job: conf.loki_job_name.clone(),
                session: data.session,
                app: data.app,
                loglevel: classify(&*conf, &data.typ),
                typ: data.typ,
                ua: ua.0.to_owned(),
            },
            values: [(
                Utc::now().timestamp_nanos().to_string(),
                data.data.get().to_owned(),
            )],
        }],
    };

    tx.send(req).unwrap();
    Response::build()
        .status(Status::Ok)
        .header(header::AccessControlAllowOrigin::Any)
        .finalize()
}

fn main() {
    tracing_subscriber::fmt::init();

    let config: Config = envy::prefixed("JS_ERROR_REPORTING_").from_env().unwrap();

    let (tx, rx) = mpsc::sync_channel(10);
    thread::spawn(move || send_thread(rx));
    rocket::ignite()
        .manage(tx)
        .manage(config)
        .mount("/", routes![log, log_opts])
        .launch();
}
