require('../external/Stats')
require('./webgl')

class MAC
  constructor: ->
    console.log "GLSLFluid initialzing"

    @dim = parseInt(settings.resolution)
    @gravity = [0, -1]
    @t = 0.0
    @initializeFbs()
    @initializeMouse()
    @deleted = false
    @simulate()

  delete: =>
    @deleted = true

  initializeMouse: =>
    @mouseStrength = 0.5
    @dragging = false
    @mouseCoord = [0, 0]

    window.onCanvasMouseDown = (e) =>
      @dragging = true
    window.onCanvasMouseUp = (e) =>
      @dragging = false
    window.onCanvasMouseMove = (e) =>
      x = (e.pageX - canvas.offsetLeft) / canvas.width
      y = (canvas.height - (e.pageY - canvas.offsetTop)) / canvas.height
      @mouseCoord = [x, y]


  initializeFbs: =>
    @particleFbs = new DoubleFramebuffer(@dim, @dim)
    @pressureFbs = new DoubleFramebuffer(@dim, @dim)
    @uFbs = new DoubleFramebuffer(@dim + 1, @dim)
    @vFbs = new DoubleFramebuffer(@dim, @dim + 1)
    @cellsFb = new Framebuffer(@dim, @dim)
    @backBuffer = new Framebuffer(canvas.width, canvas.height)
    @systemFb = new Framebuffer(@dim, @dim)
    @poissonSolver = new PoissonSolver(@dim)

  markCells: ()->
    prog = gpu.programs.markCells.use().setUniforms
      bufSize: [@cellsFb.width, @cellsFb.height]
      texture: @particleFbs

    gl.bindBuffer(gl.ARRAY_BUFFER, @pointIdBuffer)
    gl.vertexAttribPointer(prog.attributes.id, @pointIdBuffer.itemSize, gl.FLOAT, false, 0, 0)

    @cellsFb.bindFB().clear()
    gl.drawArrays(gl.POINTS, 0, @pointIdBuffer.numItems)

  initialize: =>
    numPoints = @dim * @dim
    pointIdBuffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, pointIdBuffer)
    pointIds = [0..numPoints - 1]
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(pointIds), gl.STATIC_DRAW)
    pointIdBuffer.itemSize = 1
    pointIdBuffer.numItems = numPoints
    @pointIdBuffer = pointIdBuffer
    @initializeSimulation()

  initializeSimulation: =>
    type = settings.initialState
    scene = 0
    offset = [0.0, 0.0]
    if type == 'dam-left'
      scene = 0
      offset = [0.05, 0.02]
    else if type == 'dam-middle'
      scene = 0
      offset = [0.25, 0.05]
    else if type == 'dam-leftmost'
      scene = 0
      offset = [0.0, 0.0]
    else if type  == 'dam-double'
      scene = 1
    else if type  == 'block-top'
      scene = 2
    else if type  == 'block-bottom'
      scene = 3

    # {value: 'stationary-bottom', label: 'Stationary (Bottom)'},
    # {value: 'stationary-top', label: 'Stationary (Top)'}
    gpu.programs.initialize.draw
      uniforms:
        bufSize: [@dim, @dim]
        offset: offset
        scene: scene
      target: @particleFbs
      vertexData: 'quad'

    @poissonSolver.reset()

  renderParticles: ()=>
    prog = gpu.programs.points.use().setUniforms
      texture: @particleFbs
      bufSize: [@dim, @dim]
      particleSize: parseFloat(settings.particleSize)

    gl.bindBuffer(gl.ARRAY_BUFFER, @pointIdBuffer)
    gl.vertexAttribPointer(prog.attributes.id, @pointIdBuffer.itemSize, gl.FLOAT, false, 0, 0)

    @backBuffer.bindFB().clear([0, 0, 0, 1])
    gl.enable gl.BLEND
    # gl.blendFunc gl.SRC_ALPHA, gl.ONE
    # gl.blendFunc gl.ONE_MINUS_SRC_ALPHA, gl.SRC_ALPHA
    # gl.blendFunc gl.ONE, gl.SRC_ALPHA
    gl.blendFunc gl.SRC_ALPHA, gl.ONE
    gl.drawArrays gl.POINTS, 0, @pointIdBuffer.numItems
    gl.disable gl.BLEND

  buildSystem: ()=>
    gpu.programs.buildSystem.draw
      uniforms:
        bufSize: [@dim, @dim]
        cells: [@cellsFb, gl.LINEAR]
        uTexture: [@uFbs, gl.NEAREST]
        vTexture: [@vFbs, gl.NEAREST]
      vertexData: 'quad'
      target: @systemFb

  moveMarkers: (deltaT)=>
    gpu.programs.moveMarkers.draw
      uniforms:
        bufSize: [@dim, @dim]
        deltaT: deltaT
        uTexture: [@uFbs, gl.LINEAR]
        vTexture: [@vFbs, gl.LINEAR]
        particleTexture: [@particleFbs, gl.NEAREST]
      vertexData: 'quad'
      target: @particleFbs

  applyPressure: ()=>
    gpu.programs.applyPressure.draw
      uniforms:
        bufSize: [@dim, @dim + 1]
        column: 0
        vTexture: [@vFbs, gl.NEATEST]
        pressureTexture: [@pressureFbs, gl.NEATEST]
      vertexData: 'quad'
      target: @vFbs

    gpu.programs.applyPressure.draw
      uniforms:
        bufSize: [@dim + 1, @dim]
        column: 1
        vTexture: [@uFbs, gl.NEATEST]
        pressureTexture: [@pressureFbs, gl.NEATEST]
      vertexData: 'quad'
      target: @uFbs

  getUseRK2: ->
    return if settings.rk2Advection then 1 else 0

  shouldBackupVelocity: ->
    0

  applyExternalForces: (deltaT)=>
    prog = gpu.programs.applyExternalForces.draw
      uniforms:
        bufSize: [@dim + 1, @dim]
        deltaT: deltaT
        acc: @gravity[0]
        dragging: @dragging * 1
        mouseCoord: @mouseCoord
        vTexture: [@uFbs, gl.NEATEST]
        isU: 1
        strength: @mouseStrength
      vertexData: 'quad'
      target: @uFbs
    prog = gpu.programs.applyExternalForces.draw
      uniforms:
        bufSize: [@dim, @dim + 1]
        deltaT: deltaT
        acc: @gravity[1]
        dragging: @dragging * 1
        mouseCoord: @mouseCoord
        vTexture: [@vFbs, gl.NEATEST]
        isU: 0
        strength: @mouseStrength
      vertexData: 'quad'
      target: @vFbs

  extrapolate: =>
    gpu.programs.extrapolate.draw
      uniforms:
        bufSize: [@dim, @dim + 1]
        column: 0
        vTexture: [@vFbs, gl.LINEAR]
      target: @vFbs
      vertexData: 'quad'
    gpu.programs.extrapolate.draw
      uniforms:
        bufSize: [@dim + 1, @dim]
        column: 0
        vTexture: [@uFbs, gl.LINEAR]
      target: @uFbs
      vertexData: 'quad'

  applyBoundaryCondAndMarkValid: =>
    gpu.programs.applyBoundaryCondAndMarkValid.draw
      uniforms:
        bufSize: [@dim, @dim + 1]
        column: 0
        vTexture: @vFbs
        cellTexture: [@cellsFb, gl.LINEAR]
      target: @vFbs
      vertexData: 'quad'
    gpu.programs.applyBoundaryCondAndMarkValid.draw
      uniforms:
        bufSize: [@dim + 1, @dim]
        column: 1
        vTexture: @uFbs
        cellTexture: [@cellsFb, gl.LINEAR]
      target: @uFbs
      vertexData: 'quad'

  advectVelocity: (deltaT)=>
    gpu.programs.advect.draw
      uniforms:
        bufSize: [@dim, @dim]
        column: 0
        deltaT: deltaT
        uTexture: [@uFbs, gl.LINEAR]
        vTexture: [@vFbs, gl.LINEAR]
      vertexData: 'quad'
      target: @vFbs.target

    gpu.programs.advect.draw
      uniforms:
        bufSize: [@dim, @dim]
        column: 1
        deltaT: deltaT
        uTexture: [@uFbs, gl.LINEAR]
        vTexture: [@vFbs, gl.LINEAR]
      vertexData: 'quad'
      target: @uFbs.target

    @uFbs.swap()
    @vFbs.swap()

  substep: (deltaT)=>
    @moveMarkers(deltaT)
    @markCells()
    @applyExternalForces(deltaT)
    @applyBoundaryCondAndMarkValid()
    @extrapolate()
    @advectVelocity(deltaT)
    @buildSystem()
    @poissonSolver.solve(@systemFb, @pressureFbs)
    @applyPressure()

  animate: =>
    if @deleted
      return
    if paused
      requestAnimationFrame @animate
      return

    deltaT = settings.timeStep
    gpu.timeingStats.end()
    gpu.fpsStats.end()
    gpu.timeingStats.begin()
    gpu.fpsStats.begin()
    steps = settings.substeps
    for i in [1..steps]
      @substep(deltaT / steps)
    @renderParticles()
    gpu.plotTexture @backBuffer, [0, 0], 1
    requestAnimationFrame @animate

  simulate: =>
    @initialize()
    requestAnimationFrame @animate

class PIC extends MAC
  animate: =>
    super()
  constructor: ->
    @dim = parseFloat(settings.resolution)
    @particleFbs = new DoubleFramebuffer(@dim, @dim)
    @pressureFbs = new DoubleFramebuffer(@dim, @dim, 1)
    @uFbs = new DoubleFramebuffer(@dim + 1, @dim)
    @vFbs = new DoubleFramebuffer(@dim, @dim + 1)
    @cellsFb = new Framebuffer(@dim, @dim)
    @systemFb = new Framebuffer(@dim, @dim)
    @backBuffer = new Framebuffer(canvas.width, canvas.height, 1)
    @poissonSolver = new PoissonSolver(@dim)
    @gravity = [0, -1]
    @t = 0.0
    @deleted = false
    @initializeMouse()
    @simulate()

  moveParticles: (deltaT)=>
    gpu.programs.moveParticles.draw
      uniforms:
        bufSize: [@dim, @dim]
        deltaT: deltaT
        uTexture: [@uFbs, gl.LINEAR]
        vTexture: [@vFbs, gl.LINEAR]
        particleTexture: [@particleFbs, gl.NEAREST]
      vertexData: 'quad'
      target: @particleFbs

  applyExternalForcesPIC: (deltaT)=>
    gpu.programs.applyExternalForcesPIC.draw
      uniforms:
        bufSize: [@dim, @dim]
        gravity: @gravity
        deltaT: deltaT
        particleTexture: [@particleFbs, gl.NEAREST]
      vertexData: 'quad'
      target: @particleFbs

  rasterize: =>
    rasterizeCompoment = (isU, fbs)=>
      prog = gpu.programs.scatterVelocity.use().setUniforms
        bufSize: [@dim, @dim]
        isU: isU
        texture: [@particleFbs, gl.NEAREST]

      fbs.target.bindFB().clear()
      gl.bindBuffer(gl.ARRAY_BUFFER, @pointIdBuffer)
      gl.vertexAttribPointer(prog.attributes.id, @pointIdBuffer.itemSize, gl.FLOAT, false, 0, 0)
      gl.enable gl.BLEND
      gl.blendFunc gl.SRC_ALPHA, gl.ONE
      gl.drawArrays gl.POINTS, 0, @pointIdBuffer.numItems
      gl.disable gl.BLEND
      fbs.swap()

      gpu.programs.normalizeVelocity.draw
        uniforms:
          bufSize: [@dim + (isU), @dim + (1 - isU)]
          vTexture: fbs
          backup: 1
        target: fbs
        vertexData: 'quad'

    rasterizeCompoment(1, @uFbs)
    # gpu.plotTexture @uFbs.source.texture, [-1, 0]
    rasterizeCompoment(0, @vFbs)

  getFlipAlpha: (deltaT)=>
    flipAlphaPerSecond = Math.pow(0.1, (1 - settings.flipBlending) * 10) - 1e-10;
    return Math.pow(flipAlphaPerSecond, deltaT)

  resample: (deltaT) =>
    gpu.programs.resample.draw
      uniforms:
        bufSize: [@dim, @dim]
        uTexture: [@uFbs, gl.LINEAR]
        vTexture: [@vFbs, gl.LINEAR]
        flipAlpha: @getFlipAlpha(deltaT)
        particleTexture: [@particleFbs, gl.NEAREST]
        deltaT: deltaT
        rk2: @getUseRK2()
      vertexData: 'quad'
      target: @particleFbs

  applyBoundaryConditions: =>
    gpu.programs.applyBoundaryConditions.draw
      uniforms:
        bufSize: [@dim, @dim + 1]
        column: 0
        vTexture: @vFbs
        cellTexture: [@cellsFb, gl.LINEAR]
      target: @vFbs
      vertexData: 'quad'
    gpu.programs.applyBoundaryConditions.draw
      uniforms:
        bufSize: [@dim + 1, @dim]
        column: 1
        vTexture: @uFbs
        cellTexture: [@cellsFb, gl.LINEAR]
      target: @uFbs
      vertexData: 'quad'

  substep: (deltaT) =>
    @markCells()
    @rasterize()
    @applyExternalForces(deltaT)
    @applyBoundaryConditions()
    @buildSystem()
    @poissonSolver.solve(@systemFb, @pressureFbs)
    @applyPressure()
    @resample(deltaT)
    @moveParticles(deltaT)




class PoissonSolver
  constructor: (@dim)->
    @fbs = (new Framebuffer(@dim, @dim) for i in [1..2])
    @reset()

  reset: =>
    @first = true

  solve: (systemFb, pressureFbs)=>
    if @first or not settings.warmStarting
      pressureFbs.source.bindFB().clear([0.5, 0, 0, 0])
      @first = false

    iterations = parseInt(settings.iterations)
    if iterations == 0
      return
    for i in [1..iterations]
      gpu.programs.jacobiSolver.draw
        uniforms:
          bufSize: [@dim, @dim]
          systemTexture: systemFb
          pressure: pressureFbs
          damping: parseFloat(settings.jacobiDamping)
        target: pressureFbs
        vertexData: 'quad'

window.initialize = ()=>
  window.gpu = new GPU()
  programs = ['initialize', 'iterate', 'points',
    'markCells', 'buildSystem', 'applyExternalForcesPIC',
    'jacobiSolver', 'advect', 'applyBoundaryConditions',
    'extrapolate', 'jacobiSolver', 'applyPressure', 'moveParticles',
    'scatterVelocity', 'normalizeVelocity', 'resample', 'applyExternalForces',
    'initialize', 'iterate', 'points',
    'markCells', 'buildSystem', 'applyExternalForcesPIC',
    'jacobiSolver', 'advect', 'applyBoundaryConditions',
    'extrapolate', 'jacobiSolver', 'applyPressure', 'moveParticles',
    'scatterVelocity', 'normalizeVelocity', 'resample', 'applyExternalForces', 'moveMarkers', 'applyBoundaryCondAndMarkValid'
  ]
  gpu.initialize programs

  resetFluid()

window.resetFluid = ()=>
  window.Fluid = if settings.method == 'mac' then MAC else PIC
  if window.fluid
    window.fluid.delete()
  window.fluid = new Fluid()
  window.paused = false

window.PoissonSolver = PoissonSolver
window.paused = false
window.simulationPause = =>
  window.paused = not paused

window.canvasClick = (e) =>
  console.log e
