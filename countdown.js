/* function to implement printf's %02d translation */

function n2(n)
{
  return n < 10 ? '0' + n : n;
}

/* main code */

document.addEventListener("DOMContentLoaded", function()
{
  var
    counter = document.getElementById('countdown'),
    count_to = [],
    min = 60, hour = min*60, day = hour*24,
    interval_id;

  // parse data passed from server into an array of integers
  count_to = counter.getAttribute('data-countdown').split(',')
             .map(el => parseInt(el));

  // if there are no countdown targets, just return without doing anything
  if(!count_to.length) { return }

  // set up a callback invoked every second
  interval_id = setInterval(function() {
    var now, days = 0, hours = 0, mins = 0, secs = 0, diff;

    // calculate number of seconds to our next countdown target
    now = Date.now();
    diff = count_to[0] - Math.floor(now / 1000);

    // if the number of seconds to the next countdown target is negative, try
    // get next countdown target by removing the current one from the array;
    // if there are no more target, unregister this callback and finish
    if(diff < 0) {
      count_to.shift();
      if(!count_to.length) {
        clearInterval(interval_id);
        return;
      } else {
        diff = count_to[0] - Math.floor(now / 1000);
      }
    }

    // split the time difference in seconds to days/hours/minutes/seconds
    if(diff) {
      days = Math.floor(diff / day);
      diff = diff % day;

      hours = Math.floor(diff / hour);
      diff = diff % hour;

      mins = Math.floor(diff / min);
      diff = diff % min;

      secs = Math.floor(diff);
    }

    // create the countdown string and put it up on the page
    if(days) {
      counter.textContent
        = days + 'd' + ', ' + n2(hours) + ':' + n2(mins) + ':' + n2(secs);
      } else {
      counter.textContent
        = n2(hours) + ':' + n2(mins) + ':' + n2(secs);
      }
  }, 1000)

})

