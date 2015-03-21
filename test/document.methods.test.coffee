describe 'document.methods', ->
  mabolo = new Mabolo mongodb_uri

  User = mabolo.model 'User',
    name: String
    age: Number

  jysperm = null

  beforeEach ->
    User.create
      name: 'jysperm'
      age: 19
    .then (result) ->
      jysperm = result

  describe 'toObject', ->
    it 'should success', ->
      jysperm.toObject().should.be.eql
        name: 'jysperm'
        age: 19

  describe 'update', ->
    it 'should success', ->
      jysperm.update
        $set:
          age: 20
      .then ->
        jysperm.age.should.be.equal 20

  describe 'remove', ->
    it 'should success', ->
      jysperm.remove().then ->
        User.findById jysperm._id
      .then (jysperm) ->
        expect(jysperm).to.not.exists
