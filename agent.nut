// This agent gathers data from the device and pushes to Wunderground
// Talks to wunderground rapid fire server (updates of up to once every 10 sec)
// by: Nathan Seidle
//     SparkFun Electronics
// date: October 4, 2013
// license: BeerWare
//          Please use, reuse, and modify this code as you need.
//          We hope it saves you some time, or helps you learn something!
//          If you find it handy, and we meet some day, you can buy me a beer or iced tea in return.

// Example incoming serial string from device: 
// $,winddir=270,windspeedmph=0.0,windgustmph=0.0,windgustdir=0,windspdmph_avg2m=0.0,winddir_avg2m=12,windgustmph_10m=0.0,windgustdir_10m=0,humidity=998.0,tempf=-1766.2,rainin=0.00,dailyrainin=0.00,pressure=-999.00,batt_lvl=16.11,light_lvl=3.32,#

local STATION_ID = "KCOBOULD95";
local STATION_PW = "myPassWord"; //Note that you must only use alphanumerics in your password. Http post won't work otherwise.
local LOCAL_ALTITUDE_METERS = 1638; //Accurate for the roof on my house

local midnightReset = false; //Keeps track of a once per day cumulative rain reset


// When we hear something from the device, split it apart and post it
device.on("postToInternet", function(dataString) {
    
    //server.log("Incoming: " + dataString);
    
    //Break the incoming string into pieces by comma
    a <- mysplit(dataString,',');

    if(a[0] != "$" || a[16] != "#")
    {
        server.log(format("Error: incorrect frame received (%s, %s)", a[0], a[16]));
        return(0);
    }
    
    //Pull the various bits from the blob
    
    //a[0] is $
    local winddir = a[1];
    local windspeedmph = a[2];
    local windgustmph = a[3];
    local windgustdir = a[4];
    local windspdmph_avg2m = a[5];
    local winddir_avg2m = a[6];
    local windgustmph_10m = a[7];
    local windgustdir_10m = a[8];
    local humidity = a[9];
    local tempf = a[10];
    local rainin = a[11];
    local dailyrainin = a[12];
    local pressure = a[13].tofloat();
    local batt_lvl = a[14];
    local light_lvl = a[15];
    //a[16] is #
    
    //Correct for the actual orientation of the weather station
    //For my station the north indicator is pointing due west
    winddir = windCorrect(winddir);
    windgustdir = windCorrect(windgustdir);
    winddir_avg2m = windCorrect(winddir_avg2m);
    windgustdir_10m = windCorrect(windgustdir_10m);

    //Correct for negative temperatures. This is fixed in the latest libraries: https://learn.sparkfun.com/tutorials/mpl3115a2-pressure-sensor-hookup-guide
    currentTemp <- mysplit(tempf, '=');
    local badTempf = currentTemp[1].tointeger();
    if(badTempf > 200)
    {
        local tempc = (badTempf - 32) * 5/9; //Convert F to C
        tempc = (tempc<<24)>>24; //Force this 8 bit value into 32 bit variable
        tempc = ~(tempc) + 1; //Take 2s compliment
        tempc *= -1; //Assign negative sign
        tempf = tempc * 9/5 + 32; //Convert back to F
        tempf = "tempf=" + tempf; //put a string on it
    }

    //Correct for humidity out of bounds
    currentHumidity <- mysplit(humidity, '=');
    if(currentHumidity[1].tointeger() > 99) humidity = "humidity=99";
    if(currentHumidity[1].tointeger() < 0) humidity = "humidity=0";

    //Turn Pascal pressure into baromin (Inches Mercury at Altimeter Setting)
    local baromin = "baromin=" + convertToInHg(pressure);
    
    //Calculate a dew point
    currentHumidity <- mysplit(humidity, '=');
    currentTempF <- mysplit(tempf, '=');
    local dewptf = "dewptf=" + calcDewPoint(currentHumidity[1].tointeger(), currentTempF[1].tointeger());

    //Now we form the large string to pass to wunderground
    local strMainSite = "http://rtupdate.wunderground.com/weatherstation/updateweatherstation.php";

    local strID = "ID=" + STATION_ID;
    local strPW = "PASSWORD=" + STATION_PW;

    //Form the current date/time
    //Note: .month is 0 to 11!
    local currentTime = date(time(), 'u');
    local strCT = "dateutc=";
    strCT += currentTime.year + "-" + format("%02d", currentTime.month + 1) + "-" + format("%02d", currentTime.day);
    strCT += "+" + format("%02d", currentTime.hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec);
    //Not sure if wunderground expects the + or a %2B. We shall see.
    //server.log(strCT);

    local bigString = strMainSite;
    bigString += "?" + strID;
    bigString += "&" + strPW;
    bigString += "&" + strCT;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    //bigString += "&" + weather;
    //bigString += "&" + clouds;
    bigString += "&" + "softwaretype=SparkFunWeatherImp"; //Cause we can
    bigString += "&" + "realtime=1"; //You better believe it!
    bigString += "&" + "rtfreq=10"; //Set rapid fire freq to once every 10 seconds
    bigString += "&" + "action=updateraw";

    //server.log("string to send: " + bigString);
    
    //Push to Wunderground
    local request = http.post(bigString, {}, "");
    local response = request.sendsync();
    server.log("Wunderground response = " + response.body);
    server.log(batt_lvl + " " + light_lvl);

    //Get the time that this measurement was taken
    local measurementTime = "measurementTime=";
    measurementTime += currentTime.year + "-" + format("%02d", currentTime.month + 1) + "-" + format("%02d", currentTime.day);
    measurementTime += "+" + format("%02d", currentTime.hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec);

    //Now post to data.sparkfun.com
    //Here is a list of datums: measurementTime, winddir, windspeedmph, windgustmph, windgustdir, windspdmph_avg2m, winddir_avg2m, windgustmph_10m, windgustdir_10m, humidity, tempf, rainin, dailyrainin, baromin, dewptf, batt_lvl, light_lvl

    //Now we form the large string to pass to sparkfun
    local strSparkFun = "http://data.sparkfun.com/input/";
    local publicKey = "dZ4EVmE8yGCRGx5XRX1W";
    local privateKey = "private_key=myPrivateKey";

    bigString = strSparkFun;
    bigString += publicKey;
    bigString += "?" + privateKey;
    bigString += "&" + measurementTime;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    bigString += "&" + batt_lvl;
    bigString += "&" + light_lvl;
    
    server.log("string to send: " + bigString);

    //Push to SparkFun
    local request = http.get(bigString);
    local response = request.sendsync();
    server.log("SparkFun response = " + response.body);

    //Check to see if we need to send a midnight reset
    checkMidnight(1);

    server.log("Update complete!");
}); 

//Given a string, break out the direction, correct by some value
//Return a string
function windCorrect(direction) {
    temp <- mysplit(direction, '=');

    //My station's North arrow is pointing due west
    //So correct by 90 degrees
    local dir = temp[1].tointeger() - 90; 
    if(dir < 0) dir += 360;
    return(temp[0] + "=" + dir);
}

//With relative humidity and temp, calculate a dew point
//From: http://ag.arizona.edu/azmet/dewpoint.html
function calcDewPoint(relativeHumidity, tempF) {
    local tempC = (tempF - 32) * 5 / 9.0;

    local L = math.log(relativeHumidity / 100.0);
    local M = 17.27 * tempC;
    local N = 237.3 + tempC;
    local B = (L + (M / N)) / 17.27;
    local dewPoint = (237.3 * B) / (1.0 - B);
    
    //Result is in C
    //Convert back to F
    dewPoint = dewPoint * 9 / 5.0 + 32;

    //server.log("rh=" + relativeHumidity + " tempF=" + tempF + " tempC=" + tempC);
    //server.log("DewPoint = " + dewPoint);
    return(dewPoint);
}

function checkMidnight(ignore) {
    //Check to see if it's midnight. If it is, send @ to Arduino to reset time based variables
    //Calculate local time
    local d = date(time()-(7*60*60)); //-7 hours for Mountain Time
    //server.log(d.hour);
    if(d.hour == 0 && midnightReset == false){
        server.log("Sending midnight reset");
        midnightReset = true; //We should only reset once
        device.send("sendMidnightReset", 1);
    }
    else if (d.hour != 0) {
        midnightReset = false; //Reset our state
    }
}
    
//Recording to a google doc is a bit tricky. Many people have found ways of posting
//to a google form to get data into a spreadsheet. This requires a https connection
//so we use pushingbox to handle the secure connection.
//See http://productforums.google.com/forum/#!topic/docs/f4hJKF1OQOw for more info
//To push two items I had to use a GET instead of a post
function recordLevels(batt, light) {
    
    //Smash it all together
    local stringToSend = "http://api.pushingbox.com/pushingbox?devid=vB0A3446EBB4828F";
    stringToSend = stringToSend + "&" + batt; 
    stringToSend = stringToSend + "&" + light;
    //server.log("string to send: " + stringToSend); //Debugging
    
    //Push to internet
    local request = http.post(stringToSend, {}, "");
    local response = request.sendsync();
    //server.log("Google response=" + response.body);
    
    server.log("Post to spreadsheet complete.")
}

//Given pressure in pascals, convert the pressure to Altimeter Setting, inches mercury
function convertToInHg(pressure_Pa)
{
    local pressure_mb = pressure_Pa / 100; //pressure is now in millibars, 1 pascal = 0.01 millibars
    
    local part1 = pressure_mb - 0.3; //Part 1 of formula
    local part2 = 8.42288 / 100000.0;
    local part3 = math.pow((pressure_mb - 0.3), 0.190284);
    local part4 = LOCAL_ALTITUDE_METERS / part3;
    local part5 = (1.0 + (part2 * part4));
    local part6 = math.pow(part5, (1.0/0.190284));
    local altimeter_setting_pressure_mb = part1 * part6; //Output is now in adjusted millibars
    local baromin = altimeter_setting_pressure_mb * 0.02953;
    //server.log(format("%s", baromin));
    return(baromin);
}

//From Hugo: http://forums.electricimp.com/discussion/915/processing-nmea-0183-gps-strings/p1
//You rock! Thanks Hugo!
function mysplit(a, b) {
  local ret = [];
  local field = "";
  foreach(c in a) {
      if (c == b) {
          // found separator, push field
          ret.push(field);
          field="";
      } else {
          field += c.tochar(); // append to field
      }
   }
   // Push the last field
   ret.push(field);
   return ret;
}
