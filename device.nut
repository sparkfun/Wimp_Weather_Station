// Reads data from a station and pushes it to an agent
// Agent then pushes the weather data to Wunderground
// by: Nathan Seidle
//     SparkFun Electronics
// date: October 4, 2013
// license: BeerWare
//          Please use, reuse, and modify this code as you need.
//          We hope it saves you some time, or helps you learn something!
//          If you find it handy, and we meet some day, you can buy me a beer or iced tea in return.



local rxLEDToggle = 1;  // These variables keep track of rx/tx LED toggling status
local txLEDToggle = 1;

SERIAL <- hardware.uart57;

local NOCHAR = -1;

function initUart()
{
    hardware.configure(UART_57);    // Using UART on pins 5 and 7
    SERIAL.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS); // 19200 baud worked well, no parity, 1 stop bit, 8 data bits
}

function initLEDs()
{
    // LEDs are on pins 8 and 9 on the imp Shield
    // They're both active low, so writing the pin a 1 will turn the LED off
    hardware.pin8.configure(DIGITAL_OUT_OD_PULLUP);
    hardware.pin9.configure(DIGITAL_OUT_OD_PULLUP);
    hardware.pin8.write(1); //RX LED
    hardware.pin9.write(1); //TX LED
}

// This function turns an LED on/off quickly on pin 9.
// It first turns the LED on, then calls itself again in 50ms to turn the LED off
function toggleTxLED()
{
    txLEDToggle = 1 - txLEDToggle;    // toggle the txLEDtoggle variable
    hardware.pin9.write(txLEDToggle);  // TX LED is on pin 8 (active-low)
}

// This function turns an LED on/off quickly on pin 8.
// It first turns the LED on, then calls itself again in 50ms to turn the LED off
function toggleRxLED()
{
    rxLEDToggle = 1 - rxLEDToggle;    // toggle the rxLEDtoggle variable
    hardware.pin8.write(rxLEDToggle);   // RX LED is on pin 8 (active-low)
}

//When the agent detects a midnight cross over, send a reset to arduino
//This resets the cumulative rain and other daily variables
agent.on("checkMidnight", function(ignore) {
    SERIAL.write("@"); //Special midnight command
});

// Send a character to the Arduino to gather the latest data
// Pass that data onto the Agent for parsing and posting to Wunderground
function checkWeather() {
    
    //Get all the various bits from the Arduino over UART
    server.log("Gathering new weather data");
    
    //Clean out any previous characters in any buffers
    SERIAL.flush();

    //Ping the Arduino with the ! character to get the latest data
    SERIAL.write("!");

    //Wait for initial character to come in
    local counter = 0;
    local result = NOCHAR;
    while(result == NOCHAR)
    {
        result = SERIAL.read(); //Wait for a new character to arrive

        imp.sleep(0.01);
        if(counter++ > 200) //2 seconds
        {
            server.log("Serial timeout error initial");
            return(0); //Bail after 2000ms max wait 
        }
    }
    //server.log("Counter: " + counter);
    
    // Collect bytes
    local incomingStream = "";
    while (result != '\n')  // Keep reading until we see a newline
    {
        counter = 0;
        while(result == NOCHAR)
        {
            result = SERIAL.read();
    
            if(result == NOCHAR)
            {
                imp.sleep(0.01);
                if(counter++ > 20) //Wait no more than 20ms for another character
                {
                    server.log("Serial timeout error");
                    return(0); //Bail after 20ms max wait 
                }
            }
        }
        
        //server.log("Test: " + format("%c", result)); // Display in log window

        incomingStream += format("%c", result);
        toggleTxLED();  // Toggle the TX LED

        result = SERIAL.read(); //Grab the next character in the que
    }
    

    //server.log("We heard: " + format("%s", incomingStream)); // Display in log window
    server.log("Arduino read complete");

    hardware.pin9.write(1); //TX LED off

    // Send info to agent, that will in turn push to internet
    agent.send("postToInternet", incomingStream);
    
    //imp.wakeup(10.0, checkWeather);
}

// This is where our program actually starts! Previous stuff was all function and variable declaration.
initUart(); // Initialize the UART, called just once
initLEDs(); // Initialize the LEDs, called just once

// Start this party going!
checkWeather();

//Power down the imp to low power mode, then wake up after 10 seconds
//Wunderground has a minimum of 2.5 seconds between Rapidfire reports
imp.onidle(function() {
  server.log("Nothing to do, going to sleep for 10 seconds");
  server.sleepfor(10);
});

