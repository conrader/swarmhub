use super::job_delivery::{FakeCore, TestApi, drain, session, workspace};
use crate::{bots::{self, Ask, testing}, helpers::{self, Action}};
use rusqlite::params;

#[tokio::test]
async fn final_status_command_survives_history_refresh_without_a_ninth_delivery() {
    let (root, history) = testing::journal(&["Main", "Builder", "Reviewer"]);
    let w = workspace(root.path(), history);
    let core = FakeCore::start(&w.core.0);
    let builder = session(&w.history, "builder-id", "t1", 1, "idle");
    let reviewer = session(&w.history, "reviewer-id", "t2", 2, "idle");
    let launch = |agent: &serde_json::Value| agent["labels"]["swarmhub.launch"].as_str().unwrap().to_owned();
    let (a, b) = (launch(&builder), launch(&reviewer));
    core.agents(vec![builder, reviewer]);
    w.history.db().unwrap().execute(
        "UPDATE journal SET parent_bot_id='builder-id' WHERE launch_key=?1", [&a],
    ).unwrap();
    bots::noted(&w.history, "reviewer-id", &b).unwrap();
    let spool = root.path().join("spool");
    let listener = helpers::fixture::listen(w.clone(), spool.clone());
    let command = async |key: &str, ask| helpers::fixture::ask(&spool, key, Action::Bot(ask)).await;
    let send = |kind: &str| Ask::Send {
        kind: kind.into(), to: "Reviewer".into(), text: "Another question?".into(),
    };
    for id in [1, 3, 5, 7] {
        command(&a, send("ask")).await.unwrap();
        drain(&w).await;
        command(&b, Ask::Reply { id, text: "Answer.".into() }).await.unwrap();
        drain(&w).await;
    }
    assert_eq!(core.writes().len(), 8);
    for kind in ["ask", "tell"] {
        let refusal = command(&a, send(kind)).await.unwrap_err();
        assert!(refusal.contains("bot final-status 1"), "{refusal}");
    }
    let counts = || w.history.db().unwrap().query_row(
        "SELECT (SELECT count(*) FROM bot_work), (SELECT count(*) FROM bot_messages),
                (SELECT count(*) FROM bot_outbox), (SELECT count(*) FROM journal),
                (SELECT count(*) FROM bot_history WHERE code='final_status')",
        [], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?, r.get::<_, i64>(4)?)),
    ).unwrap();
    let (work, messages, outbox, journal, statuses) = counts();
    assert_eq!((work, messages, outbox, statuses), (1, 8, 8, 0));

    let file = |id, text: &str| Ask::FinalStatus { id, text: text.into() };
    let saved = command(&a, file(1, "Build passed. Release awaits approval.")).await.unwrap();
    for (key, id, text) in [(&a, 1, "Build passed. Release awaits approval."), (&b, 8, "Replacement")] {
        assert!(command(key, file(id, text)).await.unwrap().contains("already has a final status"));
    }
    drain(&w).await;
    assert_eq!(counts(), (1, 8, 8, journal, 1));
    assert_eq!(core.writes().len(), 8);

    // Open the journal independently, then refresh the same route/cursor the Mac imports.
    let db = crate::history::connection(w.history.file()).unwrap();
    let (entry, cursor): (i64, i64) = db.query_row(
        "SELECT id,id-1 FROM bot_history WHERE final_status_work=?1 AND final_status_by=?2",
        params![1, "builder-id"], |r| Ok((r.get(0)?, r.get(1)?)),
    ).unwrap();
    assert!(saved.contains(&format!("history entry #{entry}.")));
    let api = TestApi::start(root.path(), &w);
    let page = api.status(&format!("/api/bots/history?after={cursor}")).await;
    let items = page["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], entry);
    assert_eq!(items[0]["bot"], "main-id");
    assert_eq!(items[0]["kind"], "notice");
    assert_eq!(items[0]["code"], "final_status");
    assert_eq!(items[0]["final_status_work"], 1);
    assert_eq!(items[0]["final_status_by"], "builder-id");
    assert!(items[0]["text"].as_str().unwrap().ends_with("Build passed. Release awaits approval."));
    let refreshed = api.status("/api/bots/history?bot=main-id").await;
    assert_eq!(refreshed["items"], page["items"]);
    let next = api.status(&format!("/api/bots/history?after={entry}")).await;
    assert!(next["items"].as_array().unwrap().is_empty());
    listener.abort();
}
