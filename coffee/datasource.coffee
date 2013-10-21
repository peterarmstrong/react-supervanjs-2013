# Profile the first 100 frames?
PROFILE = no

# Minimal polyfill for AudioContext
window.AudioContext ||= window.webkitAudioContext or
                        window.mozAudioContext

# Minimal polyfill for requestAnimationFrame
window.requestAnimationFrame ||= window.webkitRequestAnimationFrame or
                                 window.mozRequestAnimationFrame

# Minimal polyfill for getUserMedia
navigator.getUserMedia ||= navigator.webkitGetUserMedia or
                           navigator.mozGetUserMedia or
                           navigator.msGetUserMedia

class @DataSource
  # How many samples should we analyze at once?
  ANALYSIS_WINDOW_IN_SAMPLES = 2048

  # How many samples should we use for each data point?
  # NOTE: Must be a whole number divisor of ANALYSIS_WINDOW_IN_SAMPLES
  SAMPLES_PER_DATA_POINT = 32

  # How many data points do we have, then?
  DATA_POINTS = ANALYSIS_WINDOW_IN_SAMPLES / SAMPLES_PER_DATA_POINT

  # Produce an array of data point indices to use in loops
  DATA_POINT_INDICES = [0..DATA_POINTS-1]

  # What amplitude does a given row represent in a DATA_POINTS × DATA_POINTS grid?
  ROW_AMPLITUDES = (row / (DATA_POINTS-1) for row in DATA_POINT_INDICES)

  # How far away does a grid point have to be away from a data point to fade to zero-brightness?
  DISPLAY_SPREAD = 2 / DATA_POINTS # in percent

  # Simple method to average an array of numbers
  arrayAverage = do ->
    sum = (a, b) -> a + b
    (array) -> array.reduce(sum) / array.length

  # This method produces view model data from the audio analyser
  produceData = ->
    # Read the current time-domain amplitude data
    @analyser.getByteTimeDomainData @amplitudes

    # Reduce the data according to our samples-per-data-point density
    data = for i in DATA_POINT_INDICES
      amplitude =
        if SAMPLES_PER_DATA_POINT is 1
          # No averaging necessary
          @amplitudes[i]
        else
          # Convert a slice of the amplitudes array into a regular array
          start = i * SAMPLES_PER_DATA_POINT
          amplitudesSlice = Array.apply [], @amplitudes.subarray(start, start + SAMPLES_PER_DATA_POINT)

          # Average the samples in this slice to produce this data point
          arrayAverage amplitudesSlice

      # Convert the amplitude to a percentage
      amplitude / 255

    # Synthesize view models from this data, creating a 2D grid of size SAMPLES_PER_DATA_POINT × SAMPLES_PER_DATA_POINT
    viewModels = []
    for col in DATA_POINT_INDICES
      # Which data point does this column represent?
      dataPoint = data[col]

      for row in DATA_POINT_INDICES
        # Which view model are we constructing?
        viewModelIndex = (row * DATA_POINTS) + col

        # Create the view model for this grid point
        viewModels[viewModelIndex] =
          # Calculate the brightness of a grid point according to how far away it is from the data point
          brightness: Math.min(1, Math.max(0, (DISPLAY_SPREAD - Math.abs(dataPoint - ROW_AMPLITUDES[row])) / DISPLAY_SPREAD))

    # Return the data
    viewModels

  constructor: (soundSource) ->
    # Instantiate an audio context
    @audioContext = new AudioContext

    # Create an audio analyser
    @analyser = @audioContext.createAnalyser()

    # Configure the analyser
    @analyser.fftSize = ANALYSIS_WINDOW_IN_SAMPLES
    @analyser.smoothingTimeConstant = 0.1

    # Create an empty array into which the time-domain amplitude results will be copied
    # Preallocate the same number of elements as samples in each analysis
    @amplitudes = new Uint8Array(ANALYSIS_WINDOW_IN_SAMPLES)

    # Create a sound source
    soundSource = @createSoundSource? (err, source) =>
      if err
        alert "Couldn't gain access to a microphone: #{err.name}"
      else
        # Connect the sound source to the analyser
        source.connect(@analyser)

    # If we're profiling, keep track of how many work packages have been completed
    @workPackages = 0 if PROFILE

  doWork: =>
    @workPackages++ if PROFILE

    # If this is the 1st work package, start profiling
    console.profile('work') if PROFILE and @workPackages is 1

    # Produce the data
    data = produceData.call(this)

    # Notify anyone interested in the data
    listener(data) for listener in @dataListeners

    # If this is the 100th work package, stop profiling
    console.profileEnd('work') if PROFILE and @workPackages is 100

    # Schedule the next work session
    requestAnimationFrame @doWork

  onData: (handler) ->
    # If the first listener has arrived, we should probably start working
    shouldStartWorking = (@dataListeners ||= []).length is 0

    # Add this listener
    @dataListeners.push handler

    @doWork() if shouldStartWorking

class @BoringDataSource extends @DataSource
  createSoundSource: (callback) ->
    # Instantiate an OscillatorNode
    oscillator = @audioContext.createOscillator()

    # …that produces a sine wave
    oscillator.type = oscillator.SINE

    # …at 6Hz
    oscillator.frequency.value = 16

    # Start it immediately
    oscillator.noteOn(0)

    # Pass it to the callback
    callback null, oscillator

class @FunDataSource extends @DataSource
  createSoundSource: (callback) ->
    # Ask to use the microphone
    navigator.getUserMedia { audio: true }, (mediaStream) =>
      # Use the microphone stream to create a sound source
      mediaStreamSource = @audioContext.createMediaStreamSource(mediaStream)

      # Create a compressor
      compressor = @audioContext.createDynamicsCompressor()

      # Create gain node to make up the gain lost in the compressor
      gainNode = @audioContext.createGain()

      # Calculate the makeup gain
      # TODO: Less hand waving, more math
      compressor.threshold.value = -32
      compressor.knee.value = 0
      compressor.ratio.value = 20
      compressor.attack.value = 0
      compressor.release.value = 0
      gainNode.gain.value = 4

      # Connect the sound source to the compressor
      mediaStreamSource.connect(compressor)

      # Connect the compressor to the makeup gain
      compressor.connect(gainNode)

      # Pass it to the callback
      callback null, gainNode

    # Or, maybe there was a problem acquiring access to the microphone
    , (err) -> callback err
