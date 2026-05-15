import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';

describe('URL Shortener (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }),
    );
    await app.init();

    prisma = app.get(PrismaService);
    await prisma.url.deleteMany();
  });

  afterAll(async () => {
    await prisma.url.deleteMany();
    await app.close();
  });

  describe('POST /api/v1/data/shorten', () => {
    it('returns a shortUrl for a valid longUrl', async () => {
      const res = await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl: 'https://example.com/some/long/path' })
        .expect(201);

      expect(res.body.shortUrl).toMatch(/^http.+\/[0-9a-zA-Z]+$/);
    });

    it('is idempotent — same longUrl returns same shortUrl', async () => {
      const longUrl = 'https://idempotent-test.com';

      const res1 = await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl })
        .expect(201);

      const res2 = await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl })
        .expect(201);

      expect(res1.body.shortUrl).toBe(res2.body.shortUrl);
    });

    it('returns 400 for an invalid URL', async () => {
      await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl: 'not-a-url' })
        .expect(400);
    });

    it('returns 400 for a URL without protocol', async () => {
      await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl: 'example.com' })
        .expect(400);
    });
  });

  describe('GET /api/v1/:shortUrl', () => {
    let shortCode: string;

    beforeAll(async () => {
      const res = await request(app.getHttpServer())
        .post('/api/v1/data/shorten')
        .send({ longUrl: 'https://redirect-test.com' });

      shortCode = res.body.shortUrl.split('/').at(-1);
    });

    it('redirects (302) to the original longUrl', async () => {
      const res = await request(app.getHttpServer())
        .get(`/api/v1/${shortCode}`)
        .expect(302);

      expect(res.headers.location).toBe('https://redirect-test.com');
    });

    it('returns 404 for an unknown shortUrl', async () => {
      await request(app.getHttpServer())
        .get('/api/v1/zzzzzzz')
        .expect(404);
    });
  });
});
