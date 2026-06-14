// Auto-scroll the progress log to the bottom when new messages arrive
Shiny.addCustomMessageHandler("scrollLog", function(msg) {
  var el = document.getElementById("log_output");
  if (el) el.scrollTop = el.scrollHeight;
});
